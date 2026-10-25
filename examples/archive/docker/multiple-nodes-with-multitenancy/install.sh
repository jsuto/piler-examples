#!/bin/bash
#

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="${SCRIPT_PATH%/*}"

setup_mysql_encryption() {
   local s
   local encrypt_cfg_dir="${SCRIPT_DIR}/encrypt"

   echo "${FUNCNAME[0]}"

   ### See https://mariadb.com/kb/en/file-key-management-encryption-plugin/ for more

   mkdir -p "$encrypt_cfg_dir"
   s="$(openssl rand -hex 32)"
   echo "1;${s}" > "${encrypt_cfg_dir}/keyfile"
   openssl rand -hex 128 > "${encrypt_cfg_dir}/keyfile.key"
   openssl enc -aes-256-cbc -md sha1 -pass file:"${encrypt_cfg_dir}/keyfile.key" -in "${encrypt_cfg_dir}/keyfile" -out "${encrypt_cfg_dir}/keyfile.enc"
   rm -f "${encrypt_cfg_dir}/keyfile"

   cat > "${SCRIPT_DIR}/99-encrypt.cnf" << ENCRYPT_CNF
[mariadb]

plugin_load_add = file_key_management
loose_file_key_management_filename = /etc/mysql/encrypt/keyfile.enc
loose_file_key_management_filekey = FILE:/etc/mysql/encrypt/keyfile.key
loose_file_key_management_encryption_algorithm = AES_CBC
ENCRYPT_CNF
}

setup_dot_profile() {
   echo "${FUNCNAME[0]}"

   cat > "${HOME}/.profile" << EOF
umask 0022
alias ls='ls -lAF'
EOF
}

##setup_dot_profile
setup_mysql_encryption

umask 0022

sudo mkdir -m 0755 -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

#sudo usermod -g docker ubuntu
