#!/bin/bash
set -e

save_env_file=$(mktemp)
export -p > "$save_env_file"

sudo su - $USER -c "$(echo "declare -x save_env_file=\"${{save_env_file}}\"" && cat "$save_env_file" && cat <<'EOS'
(
  echo "Running setup steps"
  {setup_steps}

  export -p > "$save_env_file"
)
EOS
)"


sudo su - $USER -c "$(cat "$save_env_file" && cat <<'EOS'
(
  echo "Running src command"
  {src_command}
)
EOS
)"
