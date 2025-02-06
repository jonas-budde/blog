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

The ‘Stream’ option must be activated for the camera's live stream to be published. Motioneye then provides a live stream on the specified port.

To make this port public, we use Cloudflare Tunnel.
This software is started on the RaspberryPi as a Docker container.

TODO: Cloudflare portal setting
TODO: Option to secure the Cloudflare Tunnel admin portal with Google etc.

Now we set the forwarding to our host in the Cloudflare portal.  This means that we can now access the locally shared live stream from the public Internet via the configured URL.

## Ergebnis

We can now securely access our bird camera from the public Internet.