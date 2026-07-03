import argparse
import hmac
import http.server
import logging
import os
import pathlib
import ssl
import subprocess
import sys
import threading
import urllib.parse

# setup logging
logger = logging.getLogger(__name__)
handler = logging.StreamHandler(sys.stdout)
handler.setFormatter(logging.Formatter("%(asctime)s [%(threadName)-12.12s] [%(levelname)-5.5s]  %(message)s"))
logger.setLevel(logging.INFO)
logger.addHandler(handler)

# setup files config
lock_file_path = "reset.lock"
fail_file_path = "fail_message"
reset_token = ""


def load_secret(path: str) -> str:
    with open(path, 'r') as f:
        secret = f.read().strip()
    if not secret:
        raise ValueError(f"Secret file {path} is empty")
    return secret


def write_fail_message(message: str):
    with open(fail_file_path, 'w') as f:
        f.write(message)

def read_fail_message():
    with open(fail_file_path, 'r') as f:
        fail_message = f.read()
    return fail_message

def reset_ongoing():
    return os.path.exists(lock_file_path)

def initiate_reset():

    # Attempt to acquire lock (create lock file atomically)
    try:
        fd = os.open(lock_file_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        with os.fdopen(fd, 'w') as file:
            file.write('')  # empty file
    except FileExistsError:
        return False

    # Execute reset (and then release lock) in a separate thread
    def reset_fun():
        try:
            # Execute the reset script
            subprocess.run(['bash', 'reset.sh'], check=True)
            logger.info("Reset successful!")
            write_fail_message("")
        except subprocess.CalledProcessError as e:
            logger.info("Reset failed :(")
            write_fail_message(str(e))
        except Exception as e:
            logger.exception("Reset failed unexpectedly :(")
            write_fail_message(str(e))
        finally:
            # Always release the lock so future reset attempts are not stuck.
            pathlib.Path(lock_file_path).unlink(missing_ok=True)

    thread = threading.Thread(target=reset_fun)
    thread.start()

    return True


class CustomHandler(http.server.SimpleHTTPRequestHandler):
    def send_text_response(self, status_code: int, body: str):
        body_bytes = body.encode()
        self.send_response(status_code)
        self.send_header('Content-type', 'text/plain')
        self.send_header('Content-Length', str(len(body_bytes)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body_bytes)
        self.wfile.flush()

    def request_authorized(self) -> bool:
        client_ip = self.client_address[0]
        expected_header = f"Bearer {reset_token}"
        received_header = self.headers.get('Authorization', '')
        if not hmac.compare_digest(received_header, expected_header):
            logger.warning(f"Rejected unauthenticated request from {client_ip}")
            body_bytes = b"Unauthorized"
            self.send_response(401)
            self.send_header('Content-type', 'text/plain')
            self.send_header('Content-Length', str(len(body_bytes)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('WWW-Authenticate', 'Bearer')
            self.end_headers()
            self.wfile.write(body_bytes)
            self.wfile.flush()
            return False

        return True

    def do_GET(self):
        parsed_path = urllib.parse.urlsplit(self.path).path
        logger.info(f"{parsed_path} request received")
        if not self.request_authorized():
            return

        match parsed_path:
            case '/reset':
                if initiate_reset():
                    logger.info("Running reset script...")
                    self.send_text_response(200, "Reset initiated, check /status")
                else:
                    logger.warning("Reset already running.")
                    self.send_text_response(202, "Reset already running, check /status")
            case "/status":
                fail_message = read_fail_message()
                if reset_ongoing():
                    logger.info("Returning ongoing status")
                    self.send_text_response(200, "Reset ongoing")
                elif fail_message:
                    logger.error("Returning error status")
                    self.send_text_response(500, f"Error executing reset script: {fail_message}")
                else:
                    logger.info("Returning ready status")
                    self.send_text_response(200, "Ready for duty!")
            case _:
                logger.info("Wrong request")
                self.send_text_response(404, "Endpoint not found")


# Parse command-line arguments
parser = argparse.ArgumentParser(description='Start a simple HTTP server to execute a reset script.')
parser.add_argument('--host', default='127.0.0.1', help='Host address the server will bind to')
parser.add_argument('--port', type=int, required=True, help='Port number the server will listen to')
parser.add_argument('--token-file', required=True, help='File containing the bearer token required for reset endpoints')
parser.add_argument('--certfile', required=True, help='TLS certificate file for the reset server')
parser.add_argument('--keyfile', required=True, help='TLS private key file for the reset server')
args = parser.parse_args()
reset_token = load_secret(args.token_file)

# Clear fail and lock files
write_fail_message("")
if reset_ongoing():
    os.remove(lock_file_path)

# Run the server
with http.server.ThreadingHTTPServer((args.host, args.port), CustomHandler) as httpd:
    tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls_context.minimum_version = ssl.TLSVersion.TLSv1_2
    tls_context.load_cert_chain(certfile=args.certfile, keyfile=args.keyfile)
    httpd.socket = tls_context.wrap_socket(httpd.socket, server_side=True)

    logger.info(f'Serving HTTPS reset endpoint on {args.host}:{args.port}...')
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        httpd.server_close()
