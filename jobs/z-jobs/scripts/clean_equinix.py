#!/usr/bin/env python3

import os
import requests
import argparse
from datetime import (
    datetime,
    timedelta,
    )
import sys
import pytz
import yaml
from dateutil import parser as dp

EQUINIX_ENDPOINT = "https://api.equinix.com/metal/v1/"


def main(argv):
    parser = argparse.ArgumentParser(
        description='Delete stale machines in equinix metal.')
    parser.add_argument('metro', default="am",
                        help='The metro code to search for stale machines.')
    parser.add_argument('--hours', type=int, default=2,
                        help='Minimum age in hours.')
    parser.add_argument('--dry-run', action='store_true',
                        help='Show what would be deleted, without deleting.')
    args = parser.parse_args(argv[1:])
    cfg = get_config()

    stale_machine_ids = find_stale_machines(cfg, args.metro, args.hours)

    if len(stale_machine_ids) == 0:
        print("No stale equinix devices detected")
        return 0

    print('The following equinix devices will be deleted: {}'.format(
        ', '.join(stale_machine_ids)))
    if args.dry_run:
        return 0

    terminate_machines(cfg, stale_machine_ids)


def get_config():
    if 'JUJU_DATA' not in os.environ:
        raise Exception('JUJU_DATA envvar not defined')

    juju_home = os.environ['JUJU_DATA']
    with open(juju_home + "/credentials.yaml", "r") as stream:
        equinix_creds = yaml.safe_load(stream)["credentials"]["equinix"]
        return {
            "api_key": equinix_creds["credentials"]["api-token"],
            "project_id": equinix_creds["credentials"]["project-id"]
        }


def find_stale_machines(cfg, metro, hours):
    api_path = EQUINIX_ENDPOINT + "projects/" + cfg["project_id"] + "/devices"
    dev_res = do_get(cfg, api_path)
    all_mach_list_in_metro = filter(
        lambda v: v["facility"]["metro"]["code"] == metro, dev_res["devices"])

    # If a valid hours arg is provided, filter the machine list and only retain
    # the ones that were created before the specified hours parameter.
    if hours is not None:
        threshold = pytz.UTC.localize(datetime.now() - timedelta(hours=hours))
        all_mach_list_in_metro = filter(
            lambda v: dp.parse(v["created_at"]) < threshold,
            all_mach_list_in_metro)

    return list(map(lambda v: v["id"], all_mach_list_in_metro))


def terminate_machines(cfg, machine_ids):
    for mach_id in machine_ids:
        api_path = EQUINIX_ENDPOINT + "devices/" + mach_id
        do_delete(cfg, api_path)


def do_get(cfg, path):
    res = requests.get(path, headers={
                        "Accept": "application/json",
                        "X-Auth-Token": cfg["api_key"]})
    res.raise_for_status()
    return res.json()


def do_delete(cfg, path):
    res = requests.delete(path, headers={
                        "Accept": "application/json",
                        "X-Auth-Token": cfg["api_key"]})
    # Equinix returns 422 when attempting to delete a resource that is
    # currently being provisioned
    if res.status_code != 422:
        res.raise_for_status()


if __name__ == '__main__':
    sys.exit(main(sys.argv))
