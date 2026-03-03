# videoAnalyse Project

This project sets up a Raspberry Pi to broadcast its own Wi-Fi network and run a web server. The setup is automated through the `install.sh` script, which installs necessary packages and configures the network settings.

## Project Structure

```
videoAnalyse
├── install.sh
├── config
│   ├── dnsmasq.conf
│   ├── hostapd.conf
│   └── sysctl.conf
├── web
│   └── index.html
└── README.md
```

## Installation Instructions

1. **Clone the Repository**: 
   ```bash
   git clone https://github.com/Kiwigamer/videoAnalyse.git
   cd videoAnalyse
   ```

2. **Run the Installation Script**: 
   Execute the following command to set up the Raspberry Pi:
   ```bash
   sudo bash install.sh
   ```

## Safe Boot Behavior (Fail-safe)

By default, the Pi keeps normal client Wi-Fi mode (so SSH remains possible).

- AP mode does **not** start automatically every boot.
- AP mode starts only if you explicitly arm it before reboot.
- The AP flag is automatically reset during boot (one-time behavior).

### Commands

Arm AP mode for **next boot only**:
```bash
sudo videoanalyse-ap-once
sudo reboot
```

Check status:
```bash
sudo videoanalyse-ap-status
```

Cancel AP request before reboot:
```bash
sudo videoanalyse-ap-disarm
```

When AP mode is active, gateway is `192.168.11.1`.

## Configuration Files

- **config/dnsmasq.conf**: Configures the dnsmasq service for DHCP and DNS services. It defines the IP address range for DHCP clients and the local DNS domain.

- **config/hostapd.conf**: Configures the hostapd service to allow the Raspberry Pi to act as a wireless access point. It specifies the SSID, password, and other parameters for the Wi-Fi network.

- **config/sysctl.conf**: Enables IP forwarding on the Raspberry Pi, allowing it to route traffic between the wireless and Ethernet networks.

## Web Server

- **web/index.html**: This file serves as the main webpage hosted by the Raspberry Pi's web server. It can be accessed by clients connected to the Raspberry Pi's Wi-Fi network.

## Notes

- Ensure that your Raspberry Pi is connected to the internet during the installation process to download the necessary packages.
- After running the installation script, you may need to reboot your Raspberry Pi for the changes to take effect.