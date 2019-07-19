#!/bin/bash

# Register a partitioned OS image as an AMI in EC2.
# Only registers with HVM virtualization type and GP2 EBS volume type.

# The general process is as follows:
# * Launch a worker instance with an EBS volume that will fit the image
# * Send the image to the instance
# * Write the image to the volume
# * Create a snapshot of the volume
# * Register an AMI from the snapshot

# Image assumptions:
# * Your image is partitioned, and has a bootloader set up as required.
# * Your image supports SR-IOV (e1000) and ENA networking.
# * The image fits within the memory of the --instance-type you select.

# Environment assumptions:
# * aws-cli is set up (via environment or config) to operate EC2 in the given region.
# * The SSH key associated with --ssh-keypair is loaded in ssh-agent.
# * Some required tools are available; look just below the constants.
# * The --security-group-name you specify (or "default") has TCP port 22 open,
#      and you can access EC2 from your location

# Caveats:
# * We try to clean up the worker instance and volume, but if we're interrupted
#      in specific ways (see cleanup()) they can leak; be sure to check your
#      account and clean up as necessary.

# Tested with the Amazon Linux AMI as worker AMI.
# Example call:
#    bin/amiize.sh --image build/thar-x86_64.img --region us-west-2 \
#       --worker-ami ami-0f2176987ee50226e --ssh-keypair tjk \
#       --instance-type m3.xlarge --name thar-20190718-01 --arch x86_64 \
#       --user-data 'I2Nsb3VkLWNvbmZpZwpyZXBvX3VwZ3JhZGU6IG5vbmUK'
# This user data disables updates at boot to minimize startup time of this
# short-lived instance, so make sure to use the latest AMI.

# =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

# Constants

# Where to find the volume attached to the worker instance.
DEVICE="/dev/sdf"
# Where to store the image on the worker instance.
STORAGE="/dev/shm"
# The device name registered as the root filesystem of the AMI.
ROOT_DEVICE_NAME="/dev/xvda"

# Features we assume/enable for the image.
VIRT_TYPE="hvm"
VOLUME_TYPE="gp2"
SRIOV_FLAG="--sriov-net-support simple"
ENA_FLAG="--ena-support"

# The user won't know the server in advance.
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Maximum number of times we'll try to register the image - lets us retry in
# case of timeouts.
MAX_ATTEMPTS=2

# =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

# Early checks

# Check for required tools
for tool in jq aws du rsync dd ssh; do
   what="$(command -v "${tool}")"
   if [ "${what:0:1}" = "/" ] && [ -x "${what}" ]; then
      : # absolute path we can execute; all good
   elif [ -n "${what}" ]; then
      : # builtin or function we can execute; weird but allow flexibility
   else
      echo "** Can't find executable '${tool}'" >&2
      exit 2
   fi
done


# =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

# Helper functions

usage() {
   cat >&2 <<EOF
$(basename "${0}") --image <image_file>
                 --region <region>
                 --worker-ami <AMI ID>
                 --ssh-keypair <KEYPAIR NAME>
                 --instance-type INSTANCE-TYPE
                 --name <DESIRED AMI NAME>
                 --arch <ARCHITECTURE>
                 [ --description "My great AMI" ]
                 [ --subnet-id subnet-abcdef1234 ]
                 [ --user-data base64 ]
                 [ --volume-size 1234 ]
                 [ --security-group-name default ]

Registers the given image in the given EC2 region.

Required:
   --image                    The image file to create the AMI from
   --region                   The region to upload to
   --worker-ami               The existing AMI ID to use when creating the new snapshot
   --ssh-keypair              The SSH keypair name that's registered with EC2, to connect to worker instance
   --instance-type            Instance type launched for worker instance
   --name                     The name under which to register the image
   --arch                     The machine architecture of the image, e.g. x86_64

Optional:
   --description              The description attached to the registered AMI (defaults to name)
   --subnet-id                If the given instance type requires VPC, and you have no default VPC, specify a subnet in which to launch
   --user-data                EC2 user data for worker instance, in base64 form with no line wrapping
   --volume-size              AMI root volume size in GB (defaults to size of disk image)
   --security-group-name      A security group name that allows SSH access from this host (defaults to "default")
EOF
}

required_arg() {
   local arg="${1:?}"
   local value="${2:?}"
   if [ -z "${value}" ]; then
      echo "ERROR: ${arg} is required" >&2
      exit 2
   fi
}

parse_args() {
   while [ ${#} -gt 0 ] ; do
      case "${1}" in
         --image ) shift; IMAGE="${1}" ;;
         --region ) shift; REGION="${1}" ;;
         --worker-ami ) shift; WORKER_AMI="${1}" ;;
         --ssh-keypair ) shift; SSH_KEYPAIR="${1}" ;;
         --instance-type ) shift; INSTANCE_TYPE="${1}" ;;
         --name ) shift; NAME="${1}" ;;
         --arch ) shift; ARCH="${1}" ;;

         --description ) shift; DESCRIPTION="${1}" ;;
         --subnet-id ) shift; SUBNET_ID="${1}" ;;
         --user-data ) shift; USER_DATA="${1}" ;;
         --volume-size ) shift; VOLUME_SIZE="${1}" ;;
         --security-group-name ) shift; SECURITY_GROUP="${1}" ;;

         --help ) usage; exit 0 ;;
         *)
            echo "ERROR: Unknown argument: ${1}" >&2
            usage
            exit 2
            ;;
      esac
      shift
   done

   # Required arguments
   required_arg "--image" "${IMAGE}"
   required_arg "--region" "${REGION}"
   required_arg "--worker-ami" "${WORKER_AMI}"
   required_arg "--ssh-keypair" "${SSH_KEYPAIR}"
   required_arg "--instance-type" "${INSTANCE_TYPE}"
   required_arg "--name" "${NAME}"
   required_arg "--arch" "${ARCH}"

   if [ ! -r "${IMAGE}" ] ; then
      echo "ERROR: cannot read ${IMAGE}" >&2
      exit 2
   fi

   # Defaults

   if [ -z "${SECURITY_GROUP}" ] ; then
      SECURITY_GROUP="default"
   fi
   if [ -z "${DESCRIPTION}" ] ; then
      DESCRIPTION="${NAME}"
   fi
   # VOLUME_SIZE is defaulted below, after we calculate image size
}

cleanup() {
   # Note: this isn't perfect because the user could ctrl-C the process in a
   # way that restarts our main loop and starts another instance, replacing
   # this variable.
   if [ -n "${instance}" ]; then
      echo "Cleaning up worker instance"
      aws ec2 terminate-instances \
         --region "${REGION}" \
         --instance-ids "${instance}"
   # Clean up volume if we have it, but *not* if we have an instance - the
   # volume would still be attached to the instance, and would be deleted
   # automatically with it.
   # Note: this isn't perfect because of terminate/detach timing...
   elif [ -n "${volume}" ]; then
      echo "Cleaning up working volume"
      aws ec2 delete-volume \
         --region "${REGION}" \
         --volume-id "${volume}"
   fi
}

trap 'cleanup' EXIT

block_device_mappings() {
   local snapshot="${1:?}"
   local volume_size="${2:?}"

   cat <<-EOF | jq --compact-output .
	[
	   {
	      "DeviceName": "${ROOT_DEVICE_NAME}",
	      "Ebs": {
	         "SnapshotId": "${snapshot}",
	         "VolumeType": "${VOLUME_TYPE}",
	         "VolumeSize": ${volume_size},
	         "DeleteOnTermination": true
	      }
	   }
	]
	EOF
}

valid_resource_id() {
   prefix="${1:?}"
   id="${2?}"  # no colon; allow blank so we can use this test before we set a value
   [[ "${id}" =~ ^${prefix}-([a-f0-9]{8}|[a-f0-9]{17})$ ]]
}

# Used to check whether an AMI name is already registered, so we use the
# primary key of owner+name
find_ami() {
   name="${1:?}"
   ami=$(aws ec2 describe-images \
      --output json \
      --region "${REGION}" \
      --owners "self" \
      --filters "Name=name,Values=${name}" \
      | jq --raw-output '.Images[].ImageId')

   if ! valid_resource_id ami "${ami}"; then
      echo "Unable to find AMI ${name}" >&2
      return 1
   fi
   echo "${ami}"
   return 0
}

# Helper to check for errors
check_return() {
   local rc="${1:?}"
   local msg="${2:?}"

   if [ -z "${rc}" ] || [ -z "${msg}" ] || [ -n "${3}" ]; then
      # Developer error, don't continue
      echo '** Usage: check_return RC "message"' >&2
      exit 1
   fi

   if [ "${rc}" -ne 0 ]; then
      echo "*** ${msg}"
      return 1
   fi

   return 0
}


# =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

# Initial setup and checks

parse_args "${@}"

echo "Checking if AMI already exists with name '${NAME}'"
registered_ami="$(find_ami "${NAME}")"
if [ -n "${registered_ami}" ]; then
   echo "Warning! ${registered_ami} ${NAME} already exists in ${REGION}!" >&2
   exit 1
fi

# Determine the size of the image (in G, for EBS)
# 8G      amzn-ami-pv-2012.03.2.x86_64.ext4
# This is overridden by --volume-size if you pass that option.
image_size=$(du --apparent-size --block-size=G "${IMAGE}" | sed -r 's,^([0-9]+)G\t.*,\1,')
if [ ! "${image_size}" -gt 0 ]; then
   echo "* Couldn't find the size of the image!" >&2
   exit 1
fi

VOLUME_SIZE="${VOLUME_SIZE:-${image_size}}"


# =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

# Start our registration attempts

attempts=0
while true; do
   let attempts+=1
   if [ ${attempts} -gt ${MAX_ATTEMPTS} ]; then
      echo "ERROR! Retry limit (${MAX_ATTEMPTS}) reached!" >&2
      exit 1
   fi

   echo -e "\n* Phase 1: launch a worker instance"

   worker_block_device_mapping=$(cat <<-EOF
	[
	   {
	      "DeviceName": "${DEVICE}",
	      "Ebs": {
	         "VolumeSize": ${image_size},
	         "DeleteOnTermination": false
	      }
	   }
	]
	EOF
   )

   echo "Launching worker instance"
   instance=$(aws ec2 run-instances \
      --output json \
      --region "${REGION}" \
      --image-id "${WORKER_AMI}" \
      --instance-type "${INSTANCE_TYPE}" \
      ${SUBNET_ID:+--subnet-id "${SUBNET_ID}"} \
      ${USER_DATA:+--user-data "${USER_DATA}"} \
      --security-groups "${SECURITY_GROUP}" \
      --key "${SSH_KEYPAIR}" \
      --block-device-mapping "${worker_block_device_mapping}" \
      | jq --raw-output '.Instances[].InstanceId')

   valid_resource_id i "${instance}"
   check_return ${?} "No instance launched!" || continue
   echo "Launched worker instance ${instance}"

   echo "Waiting for the worker instance to be running"
   tries=0
   status="unknown"
   sleep 20
   while [ "${status}" != "running" ]; do
      echo "Current status: ${status}"
      if [ "${tries}" -ge 10 ]; then
         echo "* Instance didn't start running in allotted time!" >&2
         # Don't leave it hanging
         if aws ec2 terminate-instances \
            --region "${REGION}" \
            --instance-ids "${instance}"
         then
            # So the cleanup function doesn't try to stop it
            unset instance
         else
            echo "* Warning: Could not terminate instance!" >&2
         fi

         continue 2
      fi

      sleep 6
      status=$(aws ec2 describe-instances \
         --output json \
         --region "${REGION}" \
         --instance-ids "${instance}" \
         | jq --raw-output --exit-status '.Reservations[].Instances[].State.Name')

       check_return ${?} "Couldn't find instance state in describe-instances output!" || continue
       let tries+=1
   done
   echo "Found status: ${status}"

   # Get the IP to connect to, and the volume to which we write the image
   echo "Querying host IP and volume"
   json_output=$(aws ec2 describe-instances \
      --output json \
      --region "${REGION}" \
      --instance-ids "${instance}")
   check_return ${?} "Couldn't describe instance!" || continue

   jq_host_query=".Reservations[].Instances[].PublicIpAddress"
   host=$(echo "${json_output}" | jq --raw-output --exit-status "${jq_host_query}")
   check_return ${?} "Couldn't find host ip address in describe-instances output!" || continue

   jq_volumeid_query=".Reservations[].Instances[].BlockDeviceMappings[] | select(.DeviceName == \"${DEVICE}\") | .Ebs.VolumeId"
   volume=$(echo "${json_output}" | jq --raw-output --exit-status "${jq_volumeid_query}")
   check_return ${?} "Couldn't find ebs volume-id in describe-instances output!" || continue

   [ -n "${host}" ] && [ -n "${volume}" ]
   check_return ${?} "Couldn't get hostname/volume from instance description!" || continue
   echo "Found IP '${host}' and volume '${volume}'"

   echo "Waiting for SSH to be accessible"
   tries=0
   sleep 30
   # shellcheck disable=SC2029 disable=SC2086
   while ! ssh ${SSH_OPTS} "ec2-user@${host}" "test -b ${DEVICE}"; do
      [ "${tries}" -lt 10 ]
      check_return ${?} "* SSH not responding on instance!" || continue 2
      sleep 6
      let tries+=1
   done

   # =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

   echo -e "\n* Phase 2: send and write the image"

   echo "Uploading the image to the instance"
   rsync --compress --sparse --rsh="ssh ${SSH_OPTS}" \
      "${IMAGE}" "ec2-user@${host}:${STORAGE}/"
   check_return ${?} "rsync of image to volume build host failed!" || continue
   REMOTE_IMAGE="${STORAGE}/$(basename "${IMAGE}")"

   echo "Writing the image to the volume"
   # Run the script in a root shell, which requires -tt; -n is a precaution.
   # shellcheck disable=SC2029 disable=SC2086
   ssh ${SSH_OPTS} -tt "ec2-user@${host}" \
      "sudo -n dd conv=sparse conv=fsync bs=256K if=${REMOTE_IMAGE} of=${DEVICE}"
   check_return ${?} "Writing image to disk failed!" || continue

   # FIXME: do we need to udevadm settle here?

   # =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

   echo -e "\n* Phase 3: snapshot the volume"

   echo "Detaching the volume so we can snapshot it"
   aws ec2 detach-volume \
      --region "${REGION}" \
      --volume-id "${volume}"
   check_return ${?} "detach of new volume failed!" || continue

   echo "Terminating the instance"
   if aws ec2 terminate-instances \
      --region "${REGION}" \
      --instance-ids "${instance}"
   then
      # So the cleanup function doesn't try to stop it
      unset instance
   else
      echo "* Warning: Could not terminate instance!"
      # Don't die though, we got what we want...
   fi

   echo "Waiting for the volume to be 'available'"
   tries=0
   status="unknown"
   sleep 20
   while [ "${status}" != "available" ]; do
      echo "Current status: ${status}"
      [ "${tries}" -lt 20 ]
      check_return ${?} "* Volume didn't become available in allotted time!" || continue 2
      sleep 6
      status=$(aws ec2 describe-volumes \
         --output json \
         --region "${REGION}" \
         --volume-id "${volume}" \
         | jq --raw-output --exit-status '.Volumes[].State')
      check_return ${?} "Couldn't find volume state in describe-volumes output!" || continue
      let tries+=1
   done
   echo "Found status: ${status}"

   # =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

   echo "Snapshotting the volume so we can create an AMI from it"
   snapshot=$(aws ec2 create-snapshot \
      --output json \
      --region "${REGION}" \
      --description "${NAME}" \
      --volume-id "${volume}" \
      | jq --raw-output '.SnapshotId')

   valid_resource_id snap "${snapshot}"
   check_return ${?} "creating snapshot of new volume failed!" || continue

   echo "Waiting for the snapshot to complete"
   tries=0
   status="unknown"
   sleep 20
   while [ "${status}" != "completed" ]; do
      echo "Current status: ${status}"
      [ "${tries}" -lt 75 ]
      check_return ${?} "* Snapshot didn't complete in allotted time!" || continue 2
      sleep 10
      status=$(aws ec2 describe-snapshots \
         --output json \
         --region "${REGION}" \
         --snapshot-ids "${snapshot}" \
         | jq --raw-output --exit-status '.Snapshots[].State')
      check_return ${?} "Couldn't find snapshot state in describe-snapshots output!" || continue
      let tries+=1
   done
   echo "Found status: ${status}"

   echo "Deleting volume"
   if aws ec2 delete-volume \
      --region "${REGION}" \
      --volume-id "${volume}"
   then
      # So the cleanup function doesn't try to stop it
      unset volume
   else
      echo "* Warning: Could not delete volume!"
      # Don't die though, we got what we want...
   fi

   # =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=   =^..^=

   echo -e "\n* Phase 4: register the AMI"

   echo "Registering an AMI from the snapshot"
   # shellcheck disable=SC2086
   registered_ami=$(aws --region "${REGION}" ec2 register-image \
      --root-device-name "${ROOT_DEVICE_NAME}" \
      --architecture "${ARCH}" \
      ${SRIOV_FLAG} \
      ${ENA_FLAG} \
      --virtualization-type "${VIRT_TYPE}" \
      --block-device-mappings "$(block_device_mappings ${snapshot} ${VOLUME_SIZE})" \
      --name "${NAME}" \
      --description "${DESCRIPTION}")
   check_return ${?} "image registration failed!" || continue
   echo "Registered ${registered_ami}"

   echo "Waiting for the AMI to appear in a describe query"
   waits=0
   while [ ${waits} -lt 20 ]; do
      if find_ami "${NAME}" >/dev/null; then
         echo "Found AMI ${NAME}: ${registered_ami} in ${REGION}"
         exit 0
      fi
      echo "Waiting a bit more for AMI..."
      sleep 10
      let waits+=1
   done

   echo "Warning: ${registered_ami} doesn't show up in a describe yet; check the EC2 console for further status" >&2
done

echo "No attempts succeeded" >&2
exit 1