import json
import os
import re
import subprocess
import sys
import time
from argparse import ArgumentParser
from datetime import datetime, timedelta

from dateutil import parser as date_parser
from dateutil import tz


def get_env():
    env = dict(os.environ)
    # Inject snap bin so it's available regardless of which host we're run from
    env['PATH'] = '/snap/bin:{}'.format(env['PATH'])
    return env


def list_old_containers(hours, name_prefix):
    env = get_env()
    containers = json.loads(subprocess.check_output([
        'timeout', '-s', 'SIGINT', '5m',
        'lxc', 'list', '--format', 'json'], env=env))
    now = datetime.now(tz.gettz('UTC'))
    for container in containers:
        name = container['name']
        if not name.startswith(name_prefix):
            continue
        created_at = date_parser.parse(container['created_at'])
        age = now - created_at
        if age <= timedelta(hours=hours):
            continue
        yield name, age


def delete_container(container_name):
    """Force delete a container using retries.

    Sometimes there is a delay between zfs mounts being removed and the kernel
    actually considering the mounts removed (especially when using snaps).
    Try 4 times to actually delete the container before giving up.
    """
    env = get_env()
    attempt = 0
    while True:
        try:
            print("delete attempt {}".format(attempt))
            subprocess.check_output((
                'timeout', '-s', 'SIGINT', '10m',
                'lxc', 'delete', '--verbose', '--force',
                container_name), stderr=subprocess.STDOUT, env=env)
        except subprocess.CalledProcessError as e:
            # Depending on the LXD version used, depends on the case of the
            # `E`.
            pattern = re.compile(".*?(error\: not found).*?", re.IGNORECASE)
            if pattern.match(e.output):
                break
            print("delete failed: {}".format(e.output))
            if attempt >= 3:
                raise
            time.sleep(2)
            attempt += 1


def main():
    parser = ArgumentParser('Delete old juju containers')
    parser.add_argument('--dry-run', action='store_true',
                        help='Do not actually delete.')
    parser.add_argument('--hours', type=int, default=1,
                        help='Number of hours a juju container may exist.')
    parser.add_argument('--name_prefix', type=str, default="juju-",
                        help='Container name prefix for identiying test '
                             'containers.')
    args = parser.parse_args()
    print("Checking for old containers")
    for container, age in list_old_containers(args.hours, args.name_prefix):
        print('deleting {} ({} old)'.format(container, age))
        if args.dry_run:
            continue
        try:
            delete_container(container)
        except subprocess.CalledProcessError as e:
            print("couldn't delete {}, skipping".format(container))


if __name__ == '__main__':
    sys.exit(main())
