#!/bin/bash
set -e

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done
DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

source $DIR/utilities.sh

check_dep jq
check_dep openssl
check_dep curl
check_dep htpasswd
check_dep kubectl
check_dep ssh
check_dep base64
check_dep bc
check_dep ssh-keygen
check_dep openssl
check_dep awk
check_dep sed
check_dep cat

unset DATACENTER_ID
unset MASTER_PLAN
unset WORKER_PLAN
unset DOMAIN
unset EMAIL
unset MASTER_ID
unset API_KEY

stty -echo
tput civis

if [ -f ~/.kube-linode/settings.env ] ; then
    . ~/.kube-linode/settings.env
else
    touch ~/.kube-linode/settings.env
fi

read_api_key
read_datacenter
read_master_plan
read_worker_plan
read_domain
read_email
read_no_of_workers

#TODO: allow entering of username
USERNAME=$( whoami )

if [[ ! ( -f ~/.ssh/id_rsa && -f ~/.ssh/id_rsa.pub ) ]]; then
    spinner "Generating new SSH key" "ssh-keygen -b 2048 -t rsa -f ~/.ssh/id_rsa -q -N \"\""
else
    eval `ssh-agent -s` >/dev/null 2>&1
    ssh-add -l | grep -q "$(ssh-keygen -lf ~/.ssh/id_rsa  | awk '{print $2}')" || ssh-add ~/.ssh/id_rsa >/dev/null 2>&1
fi

if [ -f ~/.kube-linode/auth ]  ; then : ; else
    echo "Key in your dashboard password (Required for https://kube.$DOMAIN, https://traefik.$DOMAIN)"
    htpasswd -c ~/.kube-linode/auth $USERNAME
fi

spinner "Updating install script" update_script SCRIPT_ID

spinner "Retrieving master linode (if any)" get_master_id MASTER_ID

if ! [[ $MASTER_ID =~ ^-?[0-9]+$ ]] 2>/dev/null; then
   spinner "Retrieving list of workers" list_worker_ids WORKER_IDS
   for WORKER_ID in $WORKER_IDS; do
      spinner "${CYAN}[$WORKER_ID]${NORMAL} Deleting worker (since certs are now invalid)"\
                  "linode_api linode.delete LinodeID=$WORKER_ID skipChecks=true"
   done

   spinner "Creating master linode" "create_linode $DATACENTER_ID $MASTER_PLAN" MASTER_ID

   spinner "${CYAN}[$MASTER_ID]${NORMAL} Initializing labels" \
           "linode_api linode.update LinodeID=$MASTER_ID Label=\"master_${MASTER_ID}\" lpm_displayGroup=\"$DOMAIN (Unprovisioned)\""

   if [ -d ~/.kube-linode/certs ]; then
     spinner "${CYAN}[$MASTER_ID]${NORMAL} Removing existing certificates" "rm -rf ~/.kube-linode/certs"
   fi
fi

spinner "${CYAN}[$MASTER_ID]${NORMAL} Getting IP" "get_ip $MASTER_ID" MASTER_IP
declare "IP_$MASTER_ID=$MASTER_IP"

spinner "${CYAN}[$MASTER_ID]${NORMAL} Retrieving provision status" "is_provisioned $MASTER_ID" IS_PROVISIONED

if [ $IS_PROVISIONED = false ] ; then
  update_dns $MASTER_ID
  install master $MASTER_ID
  spinner "${CYAN}[$MASTER_ID]${NORMAL} Setting defaults for kubectl" set_kubectl_defaults
fi

tput el
echo "${CYAN}[$MASTER_ID]${NORMAL} Master provisioned (IP: $MASTER_IP)"

spinner "${CYAN}[$MASTER_ID]${NORMAL} Retrieving current number of workers" get_no_of_workers CURRENT_NO_OF_WORKERS
NO_OF_NEW_WORKERS=$( echo "$NO_OF_WORKERS - $CURRENT_NO_OF_WORKERS" | bc )

if [[ $NO_OF_NEW_WORKERS -gt 0 ]]; then
    for WORKER in $( seq $NO_OF_NEW_WORKERS ); do
        spinner "Creating worker linode" "create_linode $DATACENTER_ID $WORKER_PLAN" WORKER_ID
        linode_api linode.update LinodeID=$WORKER_ID Label="worker_${WORKER_ID}" lpm_displayGroup="$DOMAIN (Unprovisioned)" >/dev/null
        spinner "Initializing labels" "change_to_unprovisioned $WORKER_ID worker"
    done
fi

spinner "${CYAN}[$MASTER_ID]${NORMAL} Retrieving list of workers" list_worker_ids WORKER_IDS

for WORKER_ID in $WORKER_IDS; do
   spinner "${CYAN}[$WORKER_ID]${NORMAL} Getting IP" "get_ip $WORKER_ID" IP
   declare "IP_$WORKER_ID=$IP"
   if [ "$( is_provisioned $WORKER_ID )" = false ] ; then
     install worker $WORKER_ID
   fi
   tput el
   echo "${CYAN}[$WORKER_ID]${NORMAL} Worker provisioned (IP: $IP)"
done

wait

tput cnorm
stty echo
