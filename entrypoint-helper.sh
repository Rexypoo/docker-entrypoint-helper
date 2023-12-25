#!/usr/bin/env sh

# Flags:
#  -t=. #$TEMPLATE directory to infer UID/GID from
#  -U=docker # $USER to assign the UID/GID

for flag in "$@"; do
  case $flag in
    -t=*|--template=*)
      TEMPLATE="${i#*=}"
      shift
      ;;
    -U=*|--user=*)
      USER="${i#*=}"
      shift
      ;;
    *)
      # Anything else is the entrypoint and command
      ;;
  esac
done

# Set defaults
TEMPLATE="${TEMPLATE:-$(pwd)}"
USER="${USER:-docker}"
WORKDIR="${WORKDIR:-$(pwd)}"

# Infer the UID/GID
#--------------------------------------

NEW_UID=${NEW_UID:-$(stat -c "%u" "$TEMPLATE")}
NEW_GID=${NEW_GID:-$(stat -c "%g" "$TEMPLATE")}

if [ "$NEW_UID" -eq "0" ] || [ "$NEW_GID" -eq "0" ] ; then
  >&2 echo "ERROR!!!"
  >&2 echo "Tried to get permissions in accordance with:"
  >&2 echo "  Template (within container): $TEMPLATE"
  >&2 echo "  UID: $NEW_UID, GID: $NEW_GID"
  >&2 echo "This appears to be root! Aborting."
  >&2 echo "Please set user and group of template to a safe value."
  exit 1
fi

# Give $USER the UID/GID
#--------------------------------------

# Create $USER if it doesn't exist
if [ ! "grep -q \"$USER\" /etc/passwd" ]; then
  >&2 echo "Didn't find user '$USER' in /etc/passwd"
  >&2 echo "Creating user '$USER'"
  # Get a random UID/GID from 10,000 to 65,532
  while [ "${ID:-0}" -lt "10000" ] || [ "${ID:-99999}" -ge "65533" ]; do
    ID=$(od -An -tu -N2 /dev/urandom | tr -d " ")
  done
  adduser \
    --disabled-password \
    --gecos "" \
    --no-create-home \
    --uid "$ID" \
    "$USER" >/dev/null
fi

OLD_UID="$(id -u $USER)"
OLD_GID="$(id -g $USER)"

# Change owner of files belonging to the old UID
if [ "$OLD_UID" -lt "10000" ] || [ "$OLD_GID" -lt "10000" ]; then
  >&2 echo "Warning: the container default UID or GID may be unsafe."
  >&2 echo "  UID: $OLD_UID, GID: $OLD_GID"
  >&2 echo "Please assign $USER a UID/GID above 10000."
  >&2 echo "  Do not assign UID/GID 65533 or 65534, they may exist."
  >&2 echo "This script will NOT modify permissions for safety."
else
  if [ "$OLD_UID" -ne "$NEW_UID" ] && [ "$OLD_GID" -ne "$NEW_GID" ]; then
    echo "Modifying ownership of files belonging to ${USER}."
    find / -user "$USER" -exec chown "$NEW_UID":"$NEW_GID" {} \; 2>/dev/null
  fi
fi

# $ANY is a shorthand regex
# It should capture any field in /etc/passwd or /etc/group
ANY="\([^:]*\)"

# Patch /etc/passwd
OLD_PASSWD="^$USER:$ANY:$OLD_UID:$OLD_GID:$ANY:$ANY:"
NEW_PASSWD="$USER:\1:$NEW_UID:$NEW_GID:\2:$WORKDIR:"
sed -i "s|$OLD_PASSWD|$NEW_PASSWD|" /etc/passwd

# Patch /etc/group
OLD_GROUP="^$ANY:$ANY:$OLD_GID:"
NEW_GROUP="\1:\2:$NEW_GID:"
sed -i "s|$OLD_GROUP|$NEW_GROUP|" /etc/group

# su behaves inconsistently with -c followed by flags
# Workaround: run the entrypoint and commands as a standalone script
echo "#!/usr/bin/env sh" >> /usr/local/bin/invocation.sh
echo >> /usr/local/bin/invocation.sh
for ARG in "$@"; do
    printf "\"${ARG}\" " >> /usr/local/bin/invocation.sh
done
chmod a+x /usr/local/bin/invocation.sh

# The docker file permissions on OSX seem to be hopelessly broken
# Workaround:
#  Add directories the user should own to /tmp/entrypoint-helper/chown/
if [ -d "/tmp/entrypoint-helper/chown" ]; then
    chown -R "$NEW_UID":"$NEW_GID" /tmp/entrypoint-helper/chown
fi

# Drop root privileges and invoke the entrypoint
#--------------------------------------
su - "$USER" -c "/usr/local/bin/invocation.sh"
