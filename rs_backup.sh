#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)

usage() {
  cat << EOF # remove the space between << and EOF, this is due to web plugin issue
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-f] -p param_value arg1 [arg2...]

This script will manipulate backups taken with the duck.sh tool


Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
-f, --flag      Some flag description
-p, --param     Some param description
-u, --username  username for Rackspace login
-d, --sourcedir directory for local filestorage
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
}

setup_colors() {
  if [[ -t 2 ]] && [[ -z "${NO_COLOR-}" ]] && [[ "${TERM-}" != "dumb" ]]; then
    NOFORMAT='\033[0m' RED='\033[0;31m' GREEN='\033[0;32m' ORANGE='\033[0;33m' BLUE='\033[0;34m' PURPLE='\033[0;35m' CYAN='\033[0;36m' YELLOW='\033[1;33m'
  else
    NOFORMAT='' RED='' GREEN='' ORANGE='' BLUE='' PURPLE='' CYAN='' YELLOW=''
  fi
}

msg() {
  echo >&2 -e "${1-}"
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  msg "$msg"
  exit "$code"
}

parse_params() {
  # default values of variables set from params
  flag=0
  param=''
  username=''

  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    --no-color) NO_COLOR=1 ;;
    -f | --flag) flag=1 ;; # example flag
    -p | --param) # example named parameter
      param="${2-}"
      shift
      ;;
    -u | --username) # what's the rackspace username
      username="${2-}"
      shift
      ;;
    -d | --sourcedir) # what's the local data directory
      sourcedir="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  # check required params and arguments
  [[ -z "${param-}" ]] || [[ -z "${username-}" ]] || [[ -z "${sourcedir-}" ]] && die "Missing required parameter: param,username,sourcedir"
  [[ ${#args[@]} -eq 0 ]] && die "Missing script arguments"
  [[ ! -d ${sourcedir} ]] && die "Source Directory does not exist"

  return 0
}

parse_params "$@"
setup_colors

# script logic here

# BEGIN RACKSPACE KEY BLOCK Do we have an API key stored in home directory with permissions 600?
rackspace_keyfile=~/.rackspace_key

if [ ! -s ${rackspace_keyfile} > 0 ]; 
  then echo File is empty, please update ${rackspace_keyfile} to have a key=.... and a url=.. line
  exit
elif [ ! -f ${rackspace_keyfile} ]; then 
  echo File ${rackspace_keyfile} does not exist or empty, please create the file and have a key=... and a url= line with appropriate values
  exit
fi

rackspace_key_permissions=$(stat -x ${rackspace_keyfile} | grep Mode | cut -f2 -d"(" | cut -f1 -d "/" | cut -c2-4)

if [ $rackspace_key_permissions -ne 600 ] ; 
  then 
    chmod 600 $rackspace_keyfile
    echo "Permissions for ${rackspace_keyfile} UPDATED"

  else
    echo 'Permissions OK'
fi
rackspace_key=`cat $rackspace_keyfile| grep key| cut -f2 -d"="`
rackspace_url=`cat $rackspace_keyfile| grep url| cut -f2 -d"="`

echo "Key and URL ${rackspace_url} extracted from ${rackspace_keyfile} OK"
# END OF RACKSPACE API KEY BLOCK

# BEGIN PREREQUISITES INSTALL/UPDATE 

# Check O/S

unameOut="$(uname -s)"
case "${unameOut}" in
    Linux*)     machine=Linux;;
    Darwin*)    machine=Mac;;
    CYGWIN*)    machine=Cygwin;;
    MINGW*)     machine=MinGw;;
    *)          machine="UNKNOWN:${unameOut}"
esac
echo ${machine}

# Install/Update Prerequisite Applications
# duck (https://duck.sh/)
# md5sum (https://command-not-found.com/md5sum)

if [ machine = "Mac" ]; then
  
  # duck
  brew install duck
  
  # md5sum
  brew install md5sha1sum

elif [ machine = Linux ]; then
  # duck
  echo -e "[duck-stable]\nname=duck-stable\nbaseurl=https://repo.cyberduck.io/stable/\$basearch/\nenabled=1\ngpgcheck=0" | sudo tee /etc/yum.repos.d/duck-stable.repo
  sudo yum -y install duck

  # core utils/md5sum
  sudo yum -y install coreutils
fi


# END PREREQUISITE INSTALLS/UPDATES

# BEGIN EXECUTING DUCK WORKFLOW

randomized_string=`echo $RANDOM | md5sum | cut -c1-5`

# Determine file names for list purposes
rackspace_source_list=~/rackspace_source_list-${randomized_string}.list
rackspace_source_list2=~/rackspace_source_list2-${randomized_string}.list
local_source_list=~/local_source_list-${randomized_string}.list
rs_backup_output=~/rs_backup_output-${randomized_string}.out
difflist=~/rs_backup_diff-${randomized_string}.list

case "${param}" in
    download*)  
    # create a list of objects in rackspace container

      duck "-u" ${username} "-p" ${rackspace_key} "--list" ${rackspace_url}${args} | tee $rackspace_source_list

    # estimate space requirement
    # download the actual contents
      
      cd ${sourcedir}
      duck "-u" ${username} "-p" ${rackspace_key} "--parallel" "--download" ${rackspace_url}${args} ${sourcedir} | tee $rs_backup_output
      duck "-u" ${username} "-p" ${rackspace_key} "--list" ${rackspace_url}${args} | tee $rackspace_source_list2

    # create list of downloaded objects in current directory
      
      cd ${sourcedir}
      ls -1 >${local_source_list}

    # verify downloaded content with rackspace container object list (issue warning if new files are added)
      
      diff $local_source_list $rackspace_source_list | tee ${difflist}

    # verify contents between first and second lists (any new files needed?)
      
      diff $local_source_list $local_source_list2 | tee ~/rs_backup_sourcediff-${randomized_string}
      
    ;;
    Upload*)
    # create a list of objects from current directory
    # upload objects to rackspace container with parallelization
    # create list of objects in rackspace container
    # validate objects from container vs current directory
    ;;
    *)
    # 
    duck "-u" ${username} "-p" ${rackspace_key} "--"${param} ${rackspace_url}${args}    

esac

# END EXECUTION OF DUCK WORKFLOW

msg "${RED}Read parameters:${NOFORMAT}"
msg "- flag: ${flag}"
msg "- param: ${param}"
msg "- arguments: ${args[*]-}"
msg "- output files: ${rs_backup_diff}, ${rackspace_source_list}, ${rackspace_source_list2}, ${rs_backup_output},"