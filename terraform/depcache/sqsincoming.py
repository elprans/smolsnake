#!/usr/bin/env python3

# Copyright Contributors to the smolsnake project.
#
# SPDX-License-Identifier: 0BSD

from typing import (
    List,
)

import argparse
import json
import subprocess
import sys

import boto3  # type: ignore


def log(msg: str) -> None:
    print(msg, file=sys.stderr)


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="sqsincoming",
        description="Receive messages from an SQS queue and run a program",
    )

    parser.add_argument("--sqs-request-queue-url", required=True)
    parser.add_argument("--sqs-response-queue-url", required=True)
    parser.add_argument(
        "command",
        nargs=argparse.REMAINDER,
        help="Command to run on receipt of a message from the queue.",
    )

    args = parser.parse_args(argv)

    request_queue_url = args.sqs_request_queue_url
    response_queue_url = args.sqs_response_queue_url
    command = args.command

    if not args.command:
        parser.error("the following arguments are required: command")

    sqs = boto3.client("sqs")

    log(f'listening for messages on SQS queue "{request_queue_url}"')

    while True:
        response = sqs.receive_message(
            QueueUrl=request_queue_url,
            MaxNumberOfMessages=1,
            MessageAttributeNames=["All"],
            VisibilityTimeout=0,
            WaitTimeSeconds=20,
        )

        messages = response.get("Messages", [])
        if not messages:
            continue

        message = messages[0]
        receipt_handle = message["ReceiptHandle"]
        attrs = message.get("MessageAttributes", {})

        cmd = list(command)
        for attr_name, attr in attrs.items():
            if attr.get("DataType", "") == "String":
                val = attr.get("StringValue")
                if val:
                    for i, part in enumerate(cmd):
                        replaced = part.replace(f"%{attr_name}%", val)
                        if replaced != part:
                            cmd[i] = replaced

        log(f"got a message; running `{' '.join(cmd)}`")
        result = subprocess.run(
            cmd,
            input=message["Body"].encode("utf-8"),
        )

        if result.returncode != 0:
            log(f"{cmd[0]} failed with exit code {result.returncode}")
            response = {
                "status": "error",
            }
        else:
            log(f"{cmd[0]} succeeded")
            response = {
                "status": "OK",
            }

        # Delete received message from queue
        sqs.delete_message(
            QueueUrl=request_queue_url,
            ReceiptHandle=receipt_handle,
        )

        # Reply to caller.
        sqs.send_message(
            QueueUrl=response_queue_url,
            MessageAttributes={
                "RequestId": {
                    "StringValue": message["MessageId"],
                    "DataType": "String",
                },
            },
            MessageBody=json.dumps(response),
        )

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
