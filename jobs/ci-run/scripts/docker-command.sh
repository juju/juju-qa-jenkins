#!/bin/bash
set -e

SAVE_ENV="$(export -p)"
sudo su - $USER -c "$(echo "$SAVE_ENV" && cat <<'EOS'
(
  {src_command}
)
EOS
)"
