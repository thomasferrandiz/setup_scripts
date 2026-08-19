retry() {
  local retries=5
  local delay=10
  local count=0
  until "$@"; do
    count=$((count + 1))
    if [ "$count" -ge "$retries" ]; then
      echo "Command failed after $retries attempts: $*" >&2
      return 1
    fi
    echo "Attempt $count failed, retrying in $delay seconds..." >&2
    sleep "$delay"
  done
}
