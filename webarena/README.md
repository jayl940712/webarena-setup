> :warning: **This is not an official WebArena repo. For the official instructions refer to [WebArena](https://github.com/web-arena-x/webarena/tree/main/environment_docker)**

# webarena-setup

Setup scripts for webarena.

## Get the files

Download the necessary docker images from the [official webarena repo](https://github.com/web-arena-x/webarena/tree/main/environment_docker). You'll need the following files:
- shopping_final_0712.tar
- shopping_admin_final_0719.tar
- postmill-populated-exposed-withimg.tar
- gitlab-populated-final-port8023.tar
- wikipedia_en_all_maxi_2022-05.zim

Download the additional openstreetmap docker files from Zenodo:
```sh
wget https://zenodo.org/records/12636845/files/openstreetmap-website-db.tar.gz
wget https://zenodo.org/records/12636845/files/openstreetmap-website-web.tar.gz
wget https://zenodo.org/records/12636845/files/openstreetmap-website.tar.gz
```

(if you're planning to setup multiple instances, should download these files once in a shared location)

## Configure the scripts

Edit `00_vars.sh` with your ports and hostname (or ip address). You can also change `ARCHIVES_LOCATION="./"` to where your files are if you put them at a different location (like a shared folder).

## Extract / load the image files (very long, do it just once)

Untar the openstreemap docker folder:
```sh
tar -xzf ./openstreetmap-website.tar.gz
```

Create a wiki folder and move (or copy) the wikipedia file to it
```sh
mkdir wiki
mv ./wikipedia_en_all_maxi_2022-05.zim wiki/
```

Load the docker image files
```sh
sudo bash 01_docker_load_images.sh
```

Once these three steps are completed, you can get rid of the downloaded files (or unmount your shared folder) as these won't be needed any more.

## Run the server

Easiest way is to start a tmux or screen session, then run scripts 02 to 06 in order. The last script serves the homepage and should stay up.
```bash
sudo bash 02_docker_remove_containers.sh
sudo bash 03_docker_create_containers.sh
sudo bash 04_docker_start_containers.sh
sudo bash 05_docker_patch_containers.sh
sudo bash 06_serve_homepage.sh
```

Optional: to start the reset server (automated full instance resets), first create the management-only credentials and TLS material:
```bash
sudo install -d -m 700 /etc/webarena
openssl rand -hex 32 | sudo tee /etc/webarena/reset_token >/dev/null
sudo chmod 600 /etc/webarena/reset_token
sudo openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /etc/webarena/reset.key \
  -out /etc/webarena/reset.crt \
  -days 365 \
  -subj "/CN=${PUBLIC_HOSTNAME}"
sudo chmod 600 /etc/webarena/reset.key
```

Expose the reset server only on the management network or to a specific automation host. Configure these environment variables before starting it:
```bash
export RESET_PORT=7777
export RESET_BIND_HOST="<management-interface-ip>"
export RESET_TOKEN_FILE="/etc/webarena/reset_token"
export RESET_TLS_CERT="/etc/webarena/reset.crt"
export RESET_TLS_KEY="/etc/webarena/reset.key"
export RESET_TLS_CA_CERT="/etc/webarena/reset.crt"
```

Then run the reset server in a side tmux or screen terminal:
```bash
sudo bash 07_serve_reset.sh
```

The reset server listens with HTTPS and requires `Authorization: Bearer <token>`. Keep TCP/${RESET_PORT} restricted in the external ACL or security group to trusted management hosts; do not expose it to public client networks.

Then you can trigger a full instance reset with `sudo -E bash reset.sh`, which calls `https://${RESET_HOST}:${RESET_PORT}/reset` and checks status with `https://${RESET_HOST}:${RESET_PORT}/status`.

## Safety check

Go to the homepage and click each link to make sure the websites are operational (some might take ~10 secs to load the first time).

## Reset

After an agent is evaluated on WebArena, a reset is required before another agent can be evaluated.

Run scripts 02 to 06 again, or run `sudo -E bash reset.sh` if the reset server is running.
