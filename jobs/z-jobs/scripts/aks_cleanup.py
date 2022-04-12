#!/usr/bin/env python3

import yaml
import os
from datetime import datetime, timezone
from pprint import pformat

from backports.datetime_fromisoformat import MonkeyPatch
from azure.identity import ClientSecretCredential
from azure.mgmt import containerservice
from msrestazure import azure_exceptions


MAX_LIFE_IN_HOURS = 4
MonkeyPatch.patch_fromisoformat()

with open(os.path.join(os.path.dirname(os.path.realpath(__file__)), 'environments.yaml')) as f:
    environments = yaml.load(f, yaml.SafeLoader)


config = environments['environments']['aks']
resource_group = config['resource-group']


def get_poller_result(poller, wait=5):
    try:
        delay = wait
        n = 0
        while not poller.done():
            n += 1
            print(
                "\r\t=> Current status: {}, waiting for {} sec{}".format(poller.status(), delay, n * '.'),
                end='', flush=True,
            )
            poller.wait(timeout=delay)
        print()
        return poller.result()
    except azure_exceptions.CloudError as e:
        print(str(e))
        raise e


def delete_cluster(client, name):
    try:
        poller = client.managed_clusters.begin_delete(resource_group, name)
        r = get_poller_result(poller)
        if r is not None:
            print("\tcluster has been deleted -> \n%s", pformat(r.as_dict()))
    except azure_exceptions.CloudError as e:
        print(e)


def main():
    client = containerservice.ContainerServiceClient(
        credential=ClientSecretCredential(
            tenant_id=config['tenant-id'],
            client_id=config['application-id'],
            client_secret=config['application-password'],
        ),
        subscription_id=config['subscription-id']
    )
    for cluster in client.managed_clusters.list_by_resource_group(resource_group):
        if cluster.tags is None or len(cluster.tags) == 0:
            print("IGNORED: cluster {} has UNKNOWN creation time".format(cluster.name))
            continue
        createdAt = datetime.fromisoformat(cluster.tags['createdAt'])
        timedelta = datetime.now(tz=timezone.utc) - createdAt
        if timedelta.total_seconds() < MAX_LIFE_IN_HOURS * 3600:
            print(
                'IGNORED: cluster {} was created at {} (less than {} hours)'.format(
                    cluster.name, createdAt, MAX_LIFE_IN_HOURS,
                ),
            )
            continue
        print('DELETING: cluster {} was created at {}'.format(cluster.name, createdAt))
        delete_cluster(client, cluster.name)


if __name__ == '__main__':
    main()
