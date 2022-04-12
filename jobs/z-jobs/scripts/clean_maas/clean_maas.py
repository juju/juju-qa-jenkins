#!/usr/bin/env python3

import argparse
from datetime import (
    datetime,
    timedelta,
    )
import sys

from jujupy import JujuData
import substrate


def main(argv):
    parser = argparse.ArgumentParser(
        description='Delete the machines in MAAS.')
    parser.add_argument('profile', help='Name of the MAAS profile to connect to.')
    parser.add_argument('--hours', type=int, default=2, help='Minimum age in hours.')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be deleted, without deleting.')
    args = parser.parse_args(argv[1:])
    manager = substrate.MAASAccount(args.profile, '', '')

    # Grab list of machines and filter out any that are not powered on.
    powered_machines = filter(lambda v: v['power_state'] == 'on',
                          manager.machines())

    # From the list of machines that are powered on, retain the ones that
    # have been powered on before the specified hours parameter.
    if args.hours is not None:
        threshold = datetime.now() - timedelta(hours=args.hours)
        powered_machines = filter(lambda v: manager.get_poweron_date(v['system_id']) < threshold,
                          powered_machines)

    # From the remaining machines, make a list of the ones that are dynamic
    # kvm containers and can be safely deleted.
    deleted_machines = filter(lambda v: 'juju' not in v['hostname'],
                                powered_machines)
    released_machines = filter(lambda v: 'juju' in v['hostname'],
                                powered_machines)

    deleted_names = map(lambda v: v['hostname'], deleted_machines)
    released_names = map(lambda v: v['hostname'], released_machines)

    print('The following dynamic KVM machines will be deleted: {}'.format(', '.join(deleted_names)))
    print('The following machines will be released: {}'.format(', '.join(released_names)))
    if args.dry_run:
        return 0

    manager.delete_instances(m['resource_uri'] for m in deleted_machines)
    manager.terminate_instances(m['resource_uri'] for m in released_machines)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
