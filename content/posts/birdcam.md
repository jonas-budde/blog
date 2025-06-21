---
date: 2025-02-02T20:34:44+01:00
showTableOfContents: true
title: "Bird Camera"
draft: true
type: "post"
---

To observe the migratory birds every year, I installed a bird camera in the tree next to our house.

## Hardware

* [camera](https://electreeks.de/startseite/2-raspberry-pi-kamera-175-super-weitwinkelobjektiv-automatik-infrarot-sperrfilter-full-hd-mit-infrarot-leds)
* Raspberry Pi 5

## Software

* [motioneye](https://github.com/motioneye-project/motioneye)
* [cloudflare tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
* [Raspberry Pi Imager](https://www.raspberrypi.com/software/)

## Technical setup

1. Install operating system on micro sd card with Raspberry Pi Imager
    - Select your type of Raspberry Pi and chose the Raspberry Pi OS Lite (32-BIT) This is a headless image, as we don't need a ui
    - Cick the gear to configure the username, password, SSH Key, hostname and your timezone
2. Connect the raspberry pi to your network using a ethernet cable
3. ssh into machine
    - use the specified credentials from step 1
4. install motioneye using the provided bash script or with pip
    - I used this script: https://github.com/motioneye-project/motioneye/wiki/Install-On-Raspbian
    - there is a new way of installing motioneye, see https://github.com/motioneye-project/motioneye#installation
5. open motioneye using the web ui
    - the ui should be at http://ip-of-pi:8765
6. configure motioneye to create a livestream
    - https://github.com/motioneye-project/motioneye/wiki/Screenshots#add-local-camera-dialog
7. open up the livestream using your browser
    - The ‘Stream’ option must be activated for the camera's live stream to be published. Motioneye then provides a live stream on the specified port.
    - the livestream should be at http://ip-of-pi:8081
8. Make the local livestream acsessible by the whole internet using cloudflare tunnel
    - for this setup you need a cloudflare account and a own domain, there are also
    - install cloudflared using a bash script.