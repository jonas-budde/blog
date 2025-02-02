---
date: 2025-02-02T20:34:44+01:00
# description: ""
# image: ""
lastmod: 2025-02-02
showTableOfContents: false
# tags: ["",]
title: "Projekt: Vogelkamera"
draft: true
type: "post"
---
🐦‍⬛

Damit wir jedes Jahr die Zugvögel beobachten können, habe ich vor einigen Jahren eine Vogelkamera im Baum neben unserem Haus installiert.

---

## Material:

* [Kamera](https://electreeks.de/startseite/2-raspberry-pi-kamera-175-super-weitwinkelobjektiv-automatik-infrarot-sperrfilter-full-hd-mit-infrarot-leds) (Weitwinkelobjektiv und automatischer Infrarot-Sperrfilter) 

* RaspberryPi 5

## Software:


* [Motioneye](https://github.com/motioneye-project/motioneye)
* [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)

## Technischer Aufbau

Motioneye wird auf dem RaspberryPi installiert. Anschließend wird der RasperryPi mit der Kamera verbunden. Nun kann in der Motioneye Software die entsprechende Kamera ausgewählt werden.

TODO: Einstellung Kamera
TODO: Einstellung Livestream

Damit der Livestream der Kamera auch publiziert wird, muss die Option "Stream" aktiv sein. Dadurch stellt Motioneye einen Livestream auf dem angegebenen Port zur Verfügung.

Um diesen Port nun öffentlich zu machen, benutzen wir Cloudflare Tunnel.
Diese Software wird auf dem RaspberryPi als Docker Container gestartet.

TODO: Einstellung Cloudflare Portal
TODO: Möglichkeit Adminportal Cloudflare Tunnel absichern mit Google usw.

Nun stellen wir im Cloudflare Portal die Weiterleitung zu unserem Host ein. Dadurch können wir nun den lokal freigegebenen Livestream über die konfigurierte URL erreichen.

## Ergebnis

Wir können nun aus dem öffentlichen Internet sicher auf unsere Vogelkamera zugreifen.