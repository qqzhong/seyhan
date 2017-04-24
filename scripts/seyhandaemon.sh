#!/bin/bash

###  ------------------------------- ###
###  Helper methods for BASH scripts ###
###  ------------------------------- ###

source ./conf/init.sh

realpath () {
(
  TARGET_FILE="$1"
  CHECK_CYGWIN="$2"

  cd $(dirname "$TARGET_FILE")
  TARGET_FILE=$(basename "$TARGET_FILE")

  COUNT=0
  while [ -L "$TARGET_FILE" -a $COUNT -lt 100 ]
  do
      TARGET_FILE=$(readlink "$TARGET_FILE")
      cd $(dirname "$TARGET_FILE")
      TARGET_FILE=$(basename "$TARGET_FILE")
      COUNT=$(($COUNT + 1))
  done

  if [ "$TARGET_FILE" == "." -o "$TARGET_FILE" == ".." ]; then
    cd "$TARGET_FILE"
    TARGET_FILEPATH=
  else
    TARGET_FILEPATH=/$TARGET_FILE
  fi

  # make sure we grab the actual windows path, instead of cygwin's path.
  if [[ "x$CHECK_CYGWIN" == "x" ]]; then
    echo "$(pwd -P)/$TARGET_FILE"
  else
    echo $(cygwinpath "$(pwd -P)/$TARGET_FILE")
  fi
)
}

# TODO - Do we need to detect msys?

# Uses uname to detect if we're in the odd cygwin environment.
is_cygwin() {
  local os=$(uname -s)
  case "$os" in
    CYGWIN*) return 0 ;;
    *)  return 1 ;;
  esac
}

# This can fix cygwin style /cygdrive paths so we get the
# windows style paths.
cygwinpath() {
  local file="$1"
  if is_cygwin; then
    echo $(cygpath -w $file)
  else
    echo $file
  fi
}

# Make something URI friendly
make_url() {
  url="$1"
  local nospaces=${url// /%20}
  if is_cygwin; then
    echo "/${nospaces//\\//}"
  else
    echo "$nospaces"
  fi
}

# This crazy function reads in a vanilla "linux" classpath string (only : are separators, and all /),
# and returns a classpath with windows style paths, and ; separators.
fixCygwinClasspath() {
  OLDIFS=$IFS
  IFS=":"
  read -a classpath_members <<< "$1"
  declare -a fixed_members
  IFS=$OLDIFS
  for i in "${!classpath_members[@]}"
  do
    fixed_members[i]=$(realpath "${classpath_members[i]}" "fix")
  done
  IFS=";"
  echo "${fixed_members[*]}"
  IFS=$OLDIFS
}

# Fix the classpath we use for cygwin.
fix_classpath() {
  cp="$1"
  if is_cygwin; then
    echo "$(fixCygwinClasspath "$cp")"
  else 
    echo "$cp"
  fi
}
# Detect if we should use JAVA_HOME or just try PATH.
get_java_cmd() {
  if [[ -n "$JAVA_HOME" ]] && [[ -x "$JAVA_HOME/bin/java" ]];  then
    echo "$JAVA_HOME/bin/java"
  else
    echo "java"
  fi
}

echoerr () {
  echo 1>&2 "$@"
}
vlog () {
  [[ $verbose || $debug ]] && echoerr "$@"
}
dlog () {
  [[ $debug ]] && echoerr "$@"
}
execRunner () {
  # print the arguments one to a line, quoting any containing spaces
  [[ $verbose || $debug ]] && echo "# Executing command line:" && {
    for arg; do
      if printf "%s\n" "$arg" | grep -q ' '; then
        printf "\"%s\"\n" "$arg"
      else
        printf "%s\n" "$arg"
      fi
    done
    echo ""
  }

  exec "$@"
}
addJava () {
  dlog "[addJava] arg = '$1'"
  java_args=( "${java_args[@]}" "$1" )
}
addApp () {
  dlog "[addApp] arg = '$1'"
  app_commands=( "${app_commands[@]}" "$1" )
}
addResidual () {
  dlog "[residual] arg = '$1'"
  residual_args=( "${residual_args[@]}" "$1" )
}
addDebugger () {
  addJava "-Xdebug -Xrunjdwp:transport=dt_socket,server=y,suspend=n,address=$1"
}
# a ham-fisted attempt to move some memory settings in concert
# so they need not be messed around with individually.
get_mem_opts () {
  local mem=${1:-1024}
  local perm=$(( $mem / 4 ))
  (( $perm > 256 )) || perm=256
  (( $perm < 1024 )) || perm=1024
  local codecache=$(( $perm / 2 ))

  # if we detect any of these settings in ${java_opts} we need to NOT output our settings.
  # The reason is the Xms/Xmx, if they don't line up, cause errors.
  if [[ "${java_opts}" == *-Xmx* ]] || [[ "${java_opts}" == *-Xms* ]] || [[ "${java_opts}" == *-XX:MaxPermSize* ]] || [[ "${java_opts}" == *-XX:ReservedCodeCacheSize* ]]; then
     echo ""
  else 
    echo "-Xms${mem}m -Xmx${mem}m -XX:MaxPermSize=${perm}m -XX:ReservedCodeCacheSize=${codecache}m"
  fi
}
require_arg () {
  local type="$1"
  local opt="$2"
  local arg="$3"
  if [[ -z "$arg" ]] || [[ "${arg:0:1}" == "-" ]]; then
    die "$opt requires <$type> argument"
  fi
}
require_arg () {
  local type="$1"
  local opt="$2"
  local arg="$3"
  if [[ -z "$arg" ]] || [[ "${arg:0:1}" == "-" ]]; then
    die "$opt requires <$type> argument"
  fi
}
is_function_defined() {
  declare -f "$1" > /dev/null
}

# Attempt to detect if the script is running via a GUI or not
# TODO - Determine where/how we use this generically
detect_terminal_for_ui() {
  [[ ! -t 0 ]] && [[ "${#residual_args}" == "0" ]] && {
    echo "true"
  }
  # SPECIAL TEST FOR MAC
  [[ "$(uname)" == "Darwin" ]] && [[ "$HOME" == "$PWD" ]] && [[ "${#residual_args}" == "0" ]] && {
    echo "true"
  }
}

# Processes incoming arguments and places them in appropriate global variables.  called by the run method.
process_args () {
  while [[ $# -gt 0 ]]; do
    case "$1" in
       -h|-help) usage; exit 1 ;;
    -v|-verbose) verbose=1 && shift ;;
      -d|-debug) debug=1 && shift ;;

           -mem) require_arg integer "$1" "$2" && app_mem="$2" && shift 2 ;;
     -jvm-debug) require_arg port "$1" "$2" && addDebugger $2 && shift 2 ;;

     -java-home) require_arg path "$1" "$2" && java_cmd="$2/bin/java" && shift 2 ;;

            -D*) addJava "$1" && shift ;;
            -J*) addJava "${1:2}" && shift ;;
              *) addResidual "$1" && shift ;;
    esac
  done

  is_function_defined process_my_args && {
    myargs=("${residual_args[@]}")
    residual_args=()
    process_my_args "${myargs[@]}"
  }
}

# Actually runs the script.
run() {
  # TODO - check for sane environment

  # process the combined args, then reset "$@" to the residuals
  process_args "$@"
  set -- "${residual_args[@]}"
  argumentCount=$#

  #check for jline terminal fixes on cygwin
  if is_cygwin; then
    stty -icanon min 1 -echo > /dev/null 2>&1
    addJava "-Djline.terminal=jline.UnixTerminal"
    addJava "-Dsbt.cygwin=true"
  fi
  
  # Now we check to see if there are any java opts on the environemnt. These get listed first, with the script able to override them.
  if [[ "$JAVA_OPTS" != "" ]]; then
    java_opts="${JAVA_OPTS}"
  fi

  # stop the formaly instance
  "$java_cmd" -cp ./lib/stopper.jar com.seyhanproject.stopper.Stopper $http_port
  if [ -f ./RUNNING_PID ]; then
     rm RUNNING_PID
  fi
  
  # run sbt
  execRunner "$java_cmd" \
    $(get_mem_opts $app_mem) \
    ${java_opts} \
    ${java_args[@]} \
    -cp "$(fix_classpath "$app_classpath")" \
    $app_mainclass \
    "${app_commands[@]}" \
    "${residual_args[@]}"
    
  local exit_code=$?
  if is_cygwin; then
    stty icanon echo > /dev/null 2>&1
  fi
  exit $exit_code
}

# Loads a configuration file full of default command line options for this script.
loadConfigFile() {
  cat "$1" | sed '/^\#/d'
}

###  ------------------------------- ###
###  Start of customized settings    ###
###  ------------------------------- ###
usage() {
 cat <<EOM
Usage: $script_name [options]

  -h | -help         print this message
  -v | -verbose      this runner is chattier
  -d | -debug        set sbt log level to debug
  -mem    <integer>  set memory options (default: $sbt_mem, which is $(get_mem_opts $sbt_mem))
  -jvm-debug <port>  Turn on JVM debugging, open at the given port.

  # java version (default: java from PATH, currently $(java -version 2>&1 | grep version))
  -java-home <path>         alternate JAVA_HOME

  # jvm options and output control
  JAVA_OPTS          environment variable, if unset uses "$java_opts"
  -Dkey=val          pass -Dkey=val directly to the java runtime
  -J-X               pass option -X directly to the java runtime
                     (-J is stripped)

In the case of duplicated or conflicting options, the order above
shows precedence: JAVA_OPTS lowest, command line options highest.
EOM
}

###  ------------------------------- ###
###  Main script                     ###
###  ------------------------------- ###

declare -a residual_args
declare -a java_args
declare -a app_commands
declare -r real_script_path="$(realpath "$0")"
declare -r app_home="$(realpath "$(dirname "$real_script_path")")"
# TODO - Check whether this is ok in cygwin...
declare -r lib_dir="$(realpath "${app_home}/lib")"
declare -r app_mainclass="play.core.server.NettyServer"

declare -r app_classpath="$lib_dir/*"

addJava "-Duser.dir=$(cd "${app_home}"; pwd -P)"
addJava "-Dconfig.file=./conf/application.conf"
addJava "-Dlogger.file=./conf/logger.xml"
addJava "-Duser.language=en"
addJava "-Dhttp.port=$http_port"

conf_file=./conf/jvm_params.txt
if [ -f $conf_file ]; then
    configs=$(cat $conf_file)
    addJava configs
fi

declare -r java_cmd=$(get_java_cmd)

# Now check to see if it's a good enough version
# TODO - Check to see if we have a configured default java version, otherwise use 1.6
declare -r java_version=$("$java_cmd" -version 2>&1 | awk -F '"' '/version/ {print $2}')
if [[ "$java_version" == "" ]]; then
  echo
  echo No java installations was detected.
  echo Please go to http://www.java.com/getjava/ and download
  echo
  exit 1
elif [[ ! "$java_version" > "1.6" ]]; then
  echo
  echo The java installation you have is not up to date
  echo $app_name requires at least version 1.6+, you have
  echo version $java_version
  echo
  echo Please go to http://www.java.com/getjava/ and download
  echo a valid Java Runtime and install before running $app_name.
  echo
  exit 1
fi


# if configuration files exist, prepend their contents to $@ so it can be processed by this runner
[[ -f "$script_conf_file" ]] && set -- $(loadConfigFile "$script_conf_file") "$@"

my_argv=$1
shift;

case $my_argv in
start)
run "$@"  >> ./logs/seyhanserver.log 2>&1 &
echo "Seyhan starting..."
sleep 3
echo "Ok"
;;

stop)
# stop the instance
java -cp ./lib/stopper.jar com.seyhanproject.stopper.Stopper $http_port
if [ -f ./RUNNING_PID ]; then
   rm RUNNING_PID
fi
echo "Seyhan stoped"
;;

*)
echo "Usage $0 {start|stop}"
;;
esac

