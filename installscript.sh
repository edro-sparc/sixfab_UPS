#!/bin/bash

# To install new device:
# curl https://raw.githubusercontent.com/edro-sparc/sixfab_UPS/dev/installscript.sh | sh -s TOKEN_HERE
# To fleet deployment mode:
# curl https://raw.githubusercontent.com/edro-sparc/sixfab_UPS/dev/installscript.sh | sudo sh -s -- --fleet FLEET_TOKEN_HERE
# To uninstall power software:
# curl https://raw.githubusercontent.com/edro-sparc/sixfab_UPS/dev/installscript.sh | sh -s uninstall

cat <<"EOF"
 _____ _       __      _      ______                      
/  ___(_)     / _|    | |     | ___ \                     
\ `--. ___  _| |_ __ _| |__   | |_/ /____      _____ _ __ 
 `--. \ \ \/ /  _/ _` | '_ \  |  __/ _ \ \ /\ / / _ \ '__|
/\__/ / |>  <| || (_| | |_) | | | | (_) \ V  V /  __/ |   
\____/|_/_/\_\_| \__,_|_.__/  \_|  \___/ \_/\_/ \___|_|   
EOF

help() {
  echo "Usage:"
  echo "To install            :  ...commands... [DEVICE_TOKEN]"
  echo "To fleet-deployment   :  ...commands... --fleet [FLEET_TOKEN]"
  echo "To uninstall          :  ...commands... uninstall"
}

if [ "$1" = "uninstall" ]; then
  echo "Uninstalling..."
  echo "Removing sources..."
  sudo rm -r /opt/sixfab/pms >/dev/null

  echo "Removing systemctl service..."

  systemctl status pms_agent >/dev/null
  IS_PMS_AGENT_EXIST=$?
  if [ "$IS_PMS_AGENT_EXIST" = "0" ]; then
    sudo systemctl stop pms_agent >/dev/null
    sudo systemctl disable pms_agent >/dev/null
    sudo rm /etc/systemd/system/pms_agent.service >/dev/null
  fi

  systemctl status power_agent >/dev/null
  IS_POWER_AGENT_EXIST=$?
  if [ "$IS_POWER_AGENT_EXIST" = "0" ]; then
    sudo systemctl stop power_agent >/dev/null
    sudo systemctl disable power_agent >/dev/null
    sudo rm /etc/systemd/system/power_agent.service >/dev/null
    echo "Agent service deleted."
  fi

  systemctl status power_request >/dev/null
  IS_POWER_REQUEST_EXIST=$?
  if [ "$IS_POWER_REQUEST_EXIST" = "0" ]; then
    sudo systemctl stop power_request >/dev/null
    sudo systemctl disable power_request >/dev/null
    sudo rm /etc/systemd/system/power_request.service >/dev/null
    echo "Request service deleted."
  fi

  systemctl status power_check >/dev/null
  IS_POWER_CHECK_EXIST=$?
  if [ "$IS_POWER_CHECK_EXIST" = "0" ]; then
    sudo systemctl stop power_check >/dev/null
    sudo systemctl disable power_check >/dev/null
    sudo rm /etc/systemd/system/power_check.service >/dev/null
    echo "Button Check service deleted."
  else  
    echo "Button Check service not present."
  fi

  echo "Done!"
  exit 1
fi

if [ "$1" = "--fleet" ]; then
  if [ -z "$2" ]; then
    echo "[ERROR] Fleet token is missing"
    help
    exit 1
  else
    TOKEN="$2"
    IS_FLEET_DEPLOY=true
  fi
else
  if [ -z "$1" ]; then
    echo "[ERROR] Device token is missing"
    help
    exit 1
  else
    TOKEN="$1"
  fi
fi

INTERVAL="10"
AGENT_REPOSITORY="https://git.sixfab.com/sixfab-power/agent.git"
API_REPOSITORY="https://git.sixfab.com/sixfab-power/api.git"

check_distro() {
  OS_DETAILS=$(cat /etc/os-release)
  case "$OS_DETAILS" in
  *Raspbian*)
    :
    ;;
  *)
    read -p "[WARNING] The operations system is not Raspbian,  we are not supporting other operation systems/distros yet. Are you sure to continue? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
    ;;
  esac
}

update_system() {
  echo "Updating system package index..."
  sudo apt-get update >/dev/null
}

check_is_user_pi_exists() {
  if [ ! $(id -u pi) ]; then
    echo 'User pi not exists, creating...'
    sudo adduser --gecos "" pi
    sudo adduser pi sudo
    sudo adduser pi i2c
    sudo adduser pi video
    echo "pi ALL=(ALL) NOPASSWD:ALL" | sudo EDITOR='tee -a' visudo

    echo 'User created.'
  fi
}

create_basefile() {
  echo "Creating Sixfab root directory on /opt..."
  if [ ! -d "/opt/sixfab" ]; then
    sudo mkdir -p /opt/sixfab
    sudo mkdir -p /opt/edro
    echo "Root directory created."
  else
    echo "Directory already exists."
  fi
}

install_system_dependencies() {
  echo "Looking for dependencies..."

  # Check if git installed
  if ! [ -x "$(command -v git)" ]; then
    echo 'Git is not installed, installing...'
    sudo apt-get install git -y >/dev/null
  fi

  # Check if python3 installed
  if ! [ -x "$(command -v python3)" ]; then
    echo 'Python3 is not installed, installing...'
    sudo apt-get install python3 -y >/dev/null
  fi

  # Check python3 version, minimum python3.6 required
  version=$(python3 -V 2>&1 | grep -Po '(?<=Python )(.+)' | sed -e 's/\.//g')

  if [ "$version" -lt "360" ]; then
    echo "Python 3.6 or newest version required to run Sixfab Power softwares. Please upgrade Python and re-try. We are suggesting to use latest raspbian version."
    exit
  fi

  # Check if pip3 installed
  if ! [ -x "$(command -v pip3)" ]; then
    echo 'Pip for python3 is not installed, installing...'
    sudo apt-get install python3-pip -y >/dev/null
  fi

  check_system_dependencies
}

check_system_dependencies() {
  git --version >/dev/null 2>&1
  IS_GIT_INSTALLED=$?
  python3 --version >/dev/null 2>&1
  IS_PYTHON_INSTALLED=$?
  pip3 --version >/dev/null 2>&1
  IS_PIP_INSTALLED=$?
  if [ ! "$IS_GIT_INSTALLED" = "0" ] || [ ! "$IS_PYTHON_INSTALLED" = "0" ] || [ ! "$IS_PIP_INSTALLED" = "0" ]; then
    install_system_dependencies
  fi
}

fleet_deploy() {
  BOARD=$(cat /proc/cpuinfo | grep 'Revision' | awk '{print $3}')

  case $BOARD in
  "900092")
    BOARD="pi_zero"
    ;;
  "900093")
    BOARD="pi_zero"
    ;;
  "9000C1")
    BOARD="pi_zero_w"
    ;;
  "9020e0")
    BOARD="pi_3_a+"
    ;;
  "a02082")
    BOARD="pi_3_b"
    ;;
  "a22082")
    BOARD="pi_3_b"
    ;;
  "a020d3")
    BOARD="pi_3_b+"
    ;;
  "a03111")
    BOARD="pi_4_1gb"
    ;;
  "b03111")
    BOARD="pi_4_2gb"
    ;;
  "c03111")
    BOARD="pi_4_4gb"
    ;;
  "d03114")
    BOARD="pi_4_8gb"
    ;;
  *)
    BOARD="undefined"
    ;;

  esac

  if [ "$BOARD" = "undefined" ]; then
    echo "[WARNING] Your board is not supported yet."
    exit 1
  fi

  echo "Board detected: $BOARD"

  API_RESPONSE=$(python3 -c "
import sys
import json
import http.client

conn = http.client.HTTPSConnection('api.power.sixfab.com')

headers = {'Content-type': 'application/json'}
body = json.dumps({
	'board': '$BOARD',
	'uuid': '$TOKEN'
})

conn.request('POST', '/fleet_deploy', body, headers)

response = conn.getresponse()

status_code = response.status

if status_code == 200:
	uuid = json.loads(response.read().decode())['uuid']
else:
	uuid = 'None'
	
response = str(status_code)+','+str(uuid)
sys.exit(response)

" 2>&1 >/dev/null)

  API_CODE=$(echo $API_RESPONSE | cut -d "," -f1)
  API_UUID=$(echo $API_RESPONSE | cut -d "," -f2)

  case $API_CODE in
  404)
    echo "[ERROR] Fleet not found, please check UUID again"
    exit 1
    ;;
  402)
    echo "[ERROR] Reached device limit, couldn't create new device"
    exit 1
    ;;
  406)
    echo "[ERROR] Board/Raspberry Pi version not supported yet"
    exit 1
    ;;
  429)
    echo "[ERROR] Fleet don't have enough deployment quota"
    exit 1
    ;;
  esac

  TOKEN="$API_UUID"
}

enable_i2c() {
  echo "Enabling i2c..."
  sudo raspi-config nonint do_i2c 0 >/dev/null
  echo "I2C enabled."
}

install_agent() {
  if [ ! -d "/opt/sixfab/pms/agent" ]; then
    echo "Cloning agent source..."
    sudo git clone $AGENT_REPOSITORY /opt/sixfab/pms/agent >/dev/null
    echo "Agent source cloned."
  fi

  echo "Installing agent dependencies from PyPI..."
  sudo pip3 install -r /opt/sixfab/pms/agent/requirements.txt >/dev/null

  if [ -f "/opt/sixfab/.env" ]; then
    sudo sed -i "s/TOKEN=.*/TOKEN=$TOKEN/" /opt/sixfab/.env
    echo "Environment file exists, updated token."

  else
    echo "Creating environment file..."
    sudo touch /opt/sixfab/.env

    echo "[pms]
TOKEN=$TOKEN
INTERVAL=$INTERVAL
    " | sudo tee /opt/sixfab/.env
    echo "Environment file created."

  fi
}

install_distribution() {
  if [ -d "/opt/sixfab/pms/api" ]; then
    case $(cd /opt/sixfab/pms/api && sudo git show origin) in
    *sixfab*)
      sudo rm -r /opt/sixfab/pms/api
      ;;
    esac
  fi

  if [ ! -d "/opt/sixfab/pms/api" ]; then
    echo "Downloading HAT request service..."
    sudo git clone https://github.com/sixfab/power_distribution-service.git /opt/sixfab/pms/api >/dev/null
    cd /opt/sixfab/pms/api
    pip3 uninstall -y sixfab-power-python-api >/dev/null && sudo pip3 uninstall -y sixfab-power-python-api >/dev/null
    sudo pip3 install -r requirements.txt >/dev/null
    echo "Service downloaded."
  else
    echo "Updating HAT request service..."
    cd /opt/sixfab/pms/api && sudo git reset --hard HEAD >/dev/null
    cd /opt/sixfab/pms/api && sudo git pull >/dev/null
    sudo pip3 install -r /opt/sixfab/pms/api/requirements.txt >/dev/null
    echo "Service updated."
  fi
}

install_powerCheck(){
  if [ -d "/opt/edro" ]; then
    case $(cd /opt/edro && sudo git show origin) in
    *edro*)
      sudo rm -r /opt/edro/powerCheck
      ;;
    esac
  fi

  if [ ! -d "/opt/edro/powerCheck" ]; then
    echo "Downloading Power check service..."
    sudo git clone https://github.com/edro-sparc/powerCheck.git /opt/edro/powerCheck >/dev/null
    cd /opt/edro/powerCheck
    # pip3 uninstall -y sixfab-power-python-api >/dev/null && sudo pip3 uninstall -y sixfab-power-python-api >/dev/null
    # sudo pip3 install -r requirements.txt >/dev/null
    echo "Service downloaded."
  else
    echo "Updating HAT request service..."
    cd /opt/edro/powerCheck && sudo git reset --hard HEAD >/dev/null
    cd /opt/edro/powerCheck && sudo git pull >/dev/null
    # sudo pip3 install -r /opt/sixfab/pms/api/requirements.txt >/dev/null
    echo "Service updated."
  fi
}

initialize_services() {

  if [ ! -f "/etc/systemd/system/power_request.service" ]; then

    echo "Initializing systemd service for request service..."

    echo "[Unit]
Description=Sixfab UPS HAT Distributed API

[Service]
User=pi
ExecStart=/usr/bin/python3 /opt/sixfab/pms/api/run_server.py

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/power_request.service

    echo "Enabling and starting service."

    sudo systemctl daemon-reload
    sudo systemctl enable power_request
    sudo systemctl start power_request

    echo "Service initialized successfully."

  else
    echo "Request service already installed, restarting..."
    sudo systemctl restart power_request
  fi

  if [ ! -f "/etc/systemd/system/power_agent.service" ]; then

    echo "Initializing systemd service for agent..."

    echo "[Unit]
Description=Sixfab PMS Agent
After=network.target network-online.target
Requires=network-online.target

[Service]
ExecStart=/usr/bin/python3 -u agent.py
WorkingDirectory=/opt/sixfab/pms/agent
StandardOutput=inherit
StandardError=inherit
Restart=always
RestartSec=3
User=pi

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/power_agent.service

    echo "Enabling and starting service."

    sudo systemctl daemon-reload
    sudo systemctl enable power_agent
    sudo systemctl start power_agent

    echo "Service initialized successfully."

  else
    echo "Agent already installed, restarting..."
    sudo systemctl restart power_agent
  fi

}

initialize_powerCheck_service() {
	  if [ ! -f "/etc/systemd/system/power_check.service" ]; then

    echo "Initializing systemd service for power button check..."

    echo "[Unit]
Description=Edwin Robotics Power Button Check

[Service]
ExecStart=/usr/bin/python3 -u softHardShutdown.py
WorkingDirectory=/opt/edro/powerCheck
StandardOutput=inherit
StandardError=inherit
Restart=always
RestartSec=3
User=pi

[Install]
WantedBy=multi-user.target" | sudo tee /etc/systemd/system/power_check.service

    echo "Enabling and starting service."

    sudo systemctl daemon-reload
    sudo systemctl enable power_check
    sudo systemctl start power_check

    echo "Service initialized successfully."

  else
    echo "Power Button Check already installed, restarting..."
    sudo systemctl restart power_check
  fi
}

main() {
  check_distro
  update_system
  check_is_user_pi_exists
  create_basefile
  enable_i2c
  check_system_dependencies

  if [ "$IS_FLEET_DEPLOY" = "true" ]; then
    fleet_deploy
  fi

  install_agent
  install_distribution
  install_powerCheck
  initialize_services
  initialize_powerCheck_service
}

main
