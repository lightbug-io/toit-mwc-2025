# Event Demo (Toit & Lightbug VCard)

A demo application that shows off some of the Lightbug functionality on the Lightbug VCard, and the high level messaging capabilities of the messages.

This page is accessible over WiFi, either via a new access point, or the existing WiFi network the ESP is connected to.

![](https://i.imgur.com/uBXbtMN.png)

## Installation

Install the container on a Lightbug VCard with:

**To connect to the WiFi network the ESP / jaguar is already configured with**

```sh
jag container install demo ./main.toit -D lb-dev=1
```

**To disable jaguar, and setup an access point on the ESP**

```sh
jag container install demo ./main.toit -D jag.disabled -D jag.timeout=240h
```
