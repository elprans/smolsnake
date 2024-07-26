#!/usr/bin/env bash
#
# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD

set -eEx -o pipefail
shopt -s extglob
export LC_ALL=C

_input="$(cat)"

eval "$(echo "$_input" | \
        jq -r '@sh "func_dir=\(.func_dir)
                    region=\(.region)
                    python_version=\(.python_version)
                    request_queue_url=\(.request_queue_url)
                    response_queue_url=\(.response_queue_url)"')"

current_dir="$(pwd)"
package_zip="${current_dir}/function.zip"

tmp_dir="$(mktemp -d)"
function tmpfile_cleanup {
  if [ -e "$tmp_dir" ]; then
    rm -rf "$tmp_dir" >&2
  fi
}
trap tmpfile_cleanup EXIT

# Resolve dependencies and produce a lock file.
smolsnake lock \
    --python-version="${python_version}" \
    --function-source-path="${func_dir}" \
    --output="${tmp_dir}/deps.lock"

# Send the lock file to the dependency cache server for
# installation into an EFS filesystem.
msg_id=$(
  aws sqs send-message \
    --region="${region}" \
    --queue-url="${request_queue_url}" \
    --message-attributes="{\"PythonVersion\":{\"StringValue\": \"${python_version}\", \"DataType\": \"String\"}}" \
    --message-body="file://${tmp_dir}/deps.lock" \
  | jq -r ".MessageId"
)

# Wait until dependencies are installed, this can potentially take
# a while if there are lots of depenencies or if they include large files.
while true; do
  echo "Waiting for cache server to finish installing dependencies..." >&2

  response=$(aws sqs receive-message \
    --region="${region}" \
    --queue-url="${response_queue_url}" \
    --message-attribute-names="RequestId" \
    --max-number-of-messages=1 \
    --wait-time-seconds=10 \
    --query="Messages[?MessageAttributes.RequestId.StringValue == '${msg_id}']" \
    --output=json)

    echo "Received response: ${response}" >&2

    if [ "$(printf "%s" "$response" | jq length)" -gt 0 ]; then
        reponse_body=$(printf "%s" "$response" | jq -r '.[0].Body')
        echo "Cache server response: ${response}" >&2
        receipt_handle=$(printf "%s" "$response" | jq -r '.[0].ReceiptHandle')
        aws sqs delete-message \
          --region="${region}" \
          --queue-url="${response_queue_url}" \
          --receipt-handle="${receipt_handle}" >&2
        break
    else
        echo "No response from cache server yet, waiting..." >&2
    fi
done

# Amend lambda_function.py with `sys.path`-injecting prelude.
smolsnake injectsyspath \
    --python-version="${python_version}" \
    --lockfile="${tmp_dir}/deps.lock" \
    --target="${tmp_dir}/prelude.py"

cat "${tmp_dir}/prelude.py" "${func_dir}/lambda_function.py" \
  > "${tmp_dir}/lambda_function.py"

# Zip and hash the function source.
cd "${func_dir}"
zip -r "$package_zip" . >&2
zip -j "$package_zip" "${tmp_dir}/lambda_function.py" >&2

hash=$(sha256sum "$package_zip" | cut -f1 -d' ')

echo "{\"package\": \"${package_zip}\", \"hash\": \"${hash}\"}"
