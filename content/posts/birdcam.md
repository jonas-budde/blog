---
date: 2025-02-02T20:34:44+01:00
lastmod: 2025-02-02
showTableOfContents: false
title: "Project: Bird Camera"
draft: true
type: "post"
---

So that we can observe the migratory birds every year, I installed a bird camera in the tree next to our house a few years ago.

---

## Material:

* [Kamera](https://electreeks.de/startseite/2-raspberry-pi-kamera-175-super-weitwinkelobjektiv-automatik-infrarot-sperrfilter-full-hd-mit-infrarot-leds)

* RaspberryPi 5

## Software:


* [Motioneye](https://github.com/motioneye-project/motioneye)
* [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)

## Technischer Aufbau

Motioneye is installed on the RaspberryPi. The RasperryPi is then connected to the camera. The appropriate camera can now be selected in the Motioneye software.

TODO: Camera settings
TODO: Setting the live stream
1. Raspberry Pi Imager - Raspi 4 , Raspberry OS Lite (32-BIT)
- Use Custom Config - Configure Username, Password, SSH Key, Hostname, Timezone
2. Connect Pi to Network
3. SSH into machine

ssh jonas@birdcam
(Enter Password)

4. Install Docker (https://docs.docker.com/engine/install/raspberry-pi-os/#install-using-the-repository)

Set up Docker's apt repository
```bash
# Add Docker's official GPG key:
sudo apt-get update
sudo apt-get install ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/raspbian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/raspbian \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
```

Install the Docker packages.
```bash
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

5. Add own User to Docker Group

```bash
sudo usermod -aG docker $USER
```
If you login again, you know can use docker. e.g. `docker ps`

6. Install portainer for docker container management

https://docs.portainer.io/start/install-ce/server/docker/linux

```bash
docker volume create portainer_data
docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data portainer/portainer-ce:2.21.5
```

7. Create Admin User in Portainer

Call https://Raspi-IP:9443
Create User

8. Deploy Motioneye using Docker Compose

https://github.com/motioneye-project/motioneye/wiki/Install-In-Docker
Install the motioneye docker container on the raspberry pi. 
https://github.com/motioneye-project/motioneye/wiki/Install-In-Docker#image-from-docker-hub
docker pull ccrisan/motioneye:master-armhf

```yaml
version: "3.5"
services:
  motioneye:
    image: ccrisan/motioneye:master-armhf
    ports:
      - "8081:8081"
      - "8765:8765"
    volumes:
      - etc_motioneye:/etc/motioneye
      - var_lib_motioneye:/var/lib/motioneye
volumes:
  etc_motioneye:
  var_lib_motioneye:
```
The ‘Stream’ option must be activated for the camera's live stream to be published. Motioneye then provides a live stream on the specified port.

To make this port public, we use Cloudflare Tunnel.
This software is started on the RaspberryPi as a Docker container.

TODO: Cloudflare portal setting
TODO: Option to secure the Cloudflare Tunnel admin portal with Google etc.

Now we set the forwarding to our host in the Cloudflare portal.  This means that we can now access the locally shared live stream from the public Internet via the configured URL.

## Ergebnis

We can now securely access our bird camera from the public Internet.