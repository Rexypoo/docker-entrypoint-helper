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

NEW_UID=$(stat -c "%u" "$TEMPLATE")
NEW_GID=$(stat -c "%g" "$TEMPLATE")

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
grep --silent "$USER" /etc/passwd
if [ "$?" -ne "0" ]; then
  >&2 echo "Didn't find user '$USER' in /etc/passwd"
  >&2 echo "Creating user '$USER'"
  adduser \
    --disabled-password \
    --no-create-home \
    --gecos "" \
    "$USER" >/dev/null
fi

OLD_UID="$(id -u $USER)"
OLD_GID="$(id -g $USER)"

# Change owner of files belonging to the old UID
find / -user "$USER" -exec chown "$NEW_UID":"$NEW_GID" {} \;

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

# Assign the workdir to the UID/GID
#--------------------------------------

chown --recursive "$NEW_UID":"$NEW_GID" "$WORKDIR"

# Drop root privileges and invoke the entrypoint
#--------------------------------------
su - "$USER" -c "$@"
