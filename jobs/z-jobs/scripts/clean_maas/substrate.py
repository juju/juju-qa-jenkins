from contextlib import (
    contextmanager,
    )
import json
import logging
import subprocess
from time import sleep
try:
    import urlparse
except ImportError:
    import urllib.parse as urlparse

from dateutil import parser as date_parser


__metaclass__ = type


log = logging.getLogger("substrate")


LIBVIRT_DOMAIN_RUNNING = 'running'
LIBVIRT_DOMAIN_SHUT_OFF = 'shut off'


class StillProvisioning(Exception):
    """Attempted to terminate instances still provisioning."""

    def __init__(self, instance_ids):
        super(StillProvisioning, self).__init__(
            'Still provisioning: {}'.format(', '.join(instance_ids)))
        self.instance_ids = instance_ids


def terminate_instances(env, instance_ids):
    if len(instance_ids) == 0:
        log.info("No instances to delete.")
        return
    with maas_account_from_boot_config(env) as substrate:
        substrate.terminate_instances(instance_ids)


def attempt_terminate_instances(account, instance_ids):
    """Initiate terminate instance method of specific handler

    :param account: Substrate account object.
    :param instance_ids: List of instance_ids to terminate
    :return: List of instance_ids failed to terminate
    """
    uncleaned_instances = []
    for instance_id in instance_ids:
        try:
            # We are calling terminate instances for each instances
            # individually so as to catch any error.
            account.terminate_instances([instance_id])
        except Exception as e:
            # Using too broad exception here because terminate_instances method
            # is handlers specific
            uncleaned_instances.append((instance_id, repr(e)))
    return uncleaned_instances


def contains_only_known_instances(known_instance_ids, possibly_known_ids):
    """Identify instance_id_list only contains ids we know about.

    :param known_instance_ids: The list of instance_ids (superset)
    :param possibly_known_ids: The list of instance_ids (subset)
    :return: True if known_instance_ids only contains
    possibly_known_ids
    """
    return set(possibly_known_ids).issubset(set(known_instance_ids))


class MAASAccount:
    """Represent a MAAS 2.0 account."""

    _API_PATH = 'api/2.0/'

    STATUS_READY = 4

    SUBNET_CONNECTION_MODES = frozenset(('AUTO', 'DHCP', 'STATIC', 'LINK_UP'))

    ACQUIRING = 'User acquiring node'

    POWERED_ON = 'Powering on'

    CREATED = 'created'

    NODE = 'node'

    def __init__(self, profile, url, oauth):
        self.profile = profile
        self.url = urlparse.urljoin(url, self._API_PATH)
        self.oauth = oauth

    def _maas(self, *args):
        """Call maas api with given arguments and parse json result."""
        output = subprocess.check_output(('maas',) + args)
        if not output:
            return None
        return json.loads(output)

    def login(self):
        """Login with the maas cli."""
        subprocess.check_call([
            'maas', 'login', self.profile, self.url, self.oauth])

    def logout(self):
        """Logout with the maas cli."""
        subprocess.check_call(['maas', 'logout', self.profile])

    def _machine_release_args(self, machine_id):
        return (self.profile, 'machine', 'release', machine_id)

    def _machine_delete_args(self, machine_id):
        return (self.profile, 'machine', 'delete', machine_id)

    def terminate_instances(self, instance_ids):
        """Terminate the specified instances."""
        for instance in instance_ids:
            maas_system_id = instance.split('/')[5]
            log.info('Terminating %s.' % instance)
            self._maas(*self._machine_release_args(maas_system_id))

    def delete_instances(self, instance_ids):
        """Delete the specified instances."""
        for instance in instance_ids:
            maas_system_id = instance.split('/')[5]
            log.info('Deleting %s.' % instance)
            self._maas(*self._machine_delete_args(maas_system_id))

    def _list_allocated_args(self):
        return (self.profile, 'machines', 'list-allocated')

    def get_allocated_nodes(self):
        """Return a dict of allocated nodes with the hostname as keys."""
        nodes = self._maas(*self._list_allocated_args())
        allocated = {node['hostname']: node for node in nodes}
        return allocated

    def get_poweron_date(self, node):
        events = self._maas(
            self.profile, 'events', 'query', 'limit=50', 'id={}'.format(node))
        for event in events['events']:
            if node != event[self.NODE]:
                raise ValueError(
                    'Node "{}" was not "{}".'.format(event[self.NODE], node))
            if event['type'] == self.POWERED_ON:
                return date_parser.parse(event[self.CREATED])
        raise LookupError('Unable to find acquire date for "{}".'.format(node))

    def get_acquire_date(self, node):
        events = self._maas(
            self.profile, 'events', 'query', 'id={}'.format(node))
        for event in events['events']:
            if node != event[self.NODE]:
                raise ValueError(
                    'Node "{}" was not "{}".'.format(event[self.NODE], node))
            if event['type'] == self.ACQUIRING:
                return date_parser.parse(event[self.CREATED])
        raise LookupError('Unable to find acquire date for "{}".'.format(node))

    def get_allocated_ips(self):
        """Return a dict of allocated ips with the hostname as keys.

        A maas node may have many ips. The method selects the first ip which
        is the address used for virsh access and ssh.
        """
        allocated = self.get_allocated_nodes()
        ips = {k: v['ip_addresses'][0] for k, v in allocated.items()
               if v['ip_addresses']}
        return ips

    def machines(self):
        """Return list of all machines."""
        return self._maas(self.profile, 'machines', 'read')

    def fabrics(self):
        """Return list of all fabrics."""
        return self._maas(self.profile, 'fabrics', 'read')

    def create_fabric(self, name, class_type=None):
        """Create a new fabric."""
        args = [self.profile, 'fabrics', 'create', 'name=' + name]
        if class_type is not None:
            args.append('class_type=' + class_type)
        return self._maas(*args)

    def delete_fabric(self, fabric_id):
        """Delete a fabric with given id."""
        return self._maas(self.profile, 'fabric', 'delete', str(fabric_id))

    def spaces(self):
        """Return list of all spaces."""
        return self._maas(self.profile, 'spaces', 'read')

    def create_space(self, name):
        """Create a new space with given name."""
        return self._maas(self.profile, 'spaces', 'create', 'name=' + name)

    def delete_space(self, space_id):
        """Delete a space with given id."""
        return self._maas(self.profile, 'space', 'delete', str(space_id))

    def create_vlan(self, fabric_id, vid, name=None):
        """Create a new vlan on fabric with given fabric_id."""
        args = [
            self.profile, 'vlans', 'create', str(fabric_id), 'vid=' + str(vid),
            ]
        if name is not None:
            args.append('name=' + name)
        return self._maas(*args)

    def delete_vlan(self, fabric_id, vid):
        """Delete a vlan on given fabric_id with vid."""
        return self._maas(
            self.profile, 'vlan', 'delete', str(fabric_id), str(vid))

    def interfaces(self, system_id):
        """Return list of interfaces belonging to node with given system_id."""
        return self._maas(self.profile, 'interfaces', 'read', system_id)

    def interface_update(self, system_id, interface_id, name=None,
                         mac_address=None, tags=None, vlan_id=None):
        """Update fields of existing interface on node with given system_id."""
        args = [
            self.profile, 'interface', 'update', system_id, str(interface_id),
        ]
        if name is not None:
            args.append('name=' + name)
        if mac_address is not None:
            args.append('mac_address=' + mac_address)
        if tags is not None:
            args.append('tags=' + tags)
        if vlan_id is not None:
            args.append('vlan=' + str(vlan_id))
        return self._maas(*args)

    def interface_create_vlan(self, system_id, parent, vlan_id):
        """Create a vlan interface on machine with given system_id."""
        args = [
            self.profile, 'interfaces', 'create-vlan', system_id,
            'parent=' + str(parent), 'vlan=' + str(vlan_id),
        ]
        # TODO(gz): Add support for optional parameters as needed.
        return self._maas(*args)

    def delete_interface(self, system_id, interface_id):
        """Delete interface on node with given system_id with interface_id."""
        return self._maas(
            self.profile, 'interface', 'delete', system_id, str(interface_id))

    def interface_link_subnet(self, system_id, interface_id, mode, subnet_id,
                              ip_address=None, default_gateway=False):
        """Link interface from given system_id and interface_id to subnet."""
        if mode not in self.SUBNET_CONNECTION_MODES:
            raise ValueError('Invalid subnet connection mode: {}'.format(mode))
        if ip_address and mode != 'STATIC':
            raise ValueError('Must be mode STATIC for ip_address')
        if default_gateway and mode not in ('AUTO', 'STATIC'):
            raise ValueError('Must be mode AUTO or STATIC for default_gateway')
        args = [
            self.profile, 'interface', 'link-subnet', system_id,
            str(interface_id), 'mode=' + mode, 'subnet=' + str(subnet_id),
        ]
        if ip_address:
            args.append('ip_address=' + ip_address)
        if default_gateway:
            args.append('default_gateway=true')
        return self._maas(*args)

    def interface_unlink_subnet(self, system_id, interface_id, link_id):
        """Unlink subnet from interface."""
        return self._maas(
            self.profile, 'interface', 'unlink-subnet', system_id,
            str(interface_id), 'id=' + str(link_id))

    def subnets(self):
        """Return list of all subnets."""
        return self._maas(self.profile, 'subnets', 'read')

    def create_subnet(self, cidr, name=None, fabric_id=None, vlan_id=None,
                      vid=None, space=None, gateway_ip=None, dns_servers=None):
        """Create a subnet with given cidr."""
        if vlan_id and vid:
            raise ValueError('Must only give one of vlan_id and vid')
        args = [self.profile, 'subnets', 'create', 'cidr=' + cidr]
        if name is not None:
            # Defaults to cidr if none is given
            args.append('name=' + name)
        if fabric_id is not None:
            # Uses default fabric if none is given
            args.append('fabric=' + str(fabric_id))
        if vlan_id is not None:
            # Uses default vlan on fabric if none is given
            args.append('vlan=' + str(vlan_id))
        if vid is not None:
            args.append('vid=' + str(vid))
        if space is not None:
            # Uses default space if none is given
            args.append('space=' + str(space))
        if gateway_ip is not None:
            args.append('gateway_ip=' + str(gateway_ip))
        if dns_servers is not None:
            args.append('dns_servers=' + str(dns_servers))
        # TODO(gz): Add support for rdns_mode and allow_proxy from MAAS 2.0
        return self._maas(*args)

    def delete_subnet(self, subnet_id):
        """Delete subnet with given subnet_id."""
        return self._maas(
            self.profile, 'subnet', 'delete', str(subnet_id))

    def ensure_cleanup(self, resource_details):
        """
        Do MAAS specific clean-up activity.
        :param resource_details: The list of resource to be cleaned up
        :return: list of resources that were not cleaned up
        """
        uncleaned_resource = []
        return uncleaned_resource


class MAAS1Account(MAASAccount):
    """Represent a MAAS 1.X account."""

    _API_PATH = 'api/1.0/'

    def _list_allocated_args(self):
        return (self.profile, 'nodes', 'list-allocated')

    def _machine_release_args(self, machine_id):
        return (self.profile, 'node', 'release', machine_id)


@contextmanager
def maas_account_from_boot_config(env):
    """Create a ContextManager for either a MAASAccount or a MAAS1Account.

    As it's not possible to tell from the maas config which version of the api
    to use, try 2.0 and if that fails on login fallback to 1.0 instead.
    """
    maas_oauth = env.get_cloud_credentials()['maas-oauth']
    args = (env.get_option('name'), env.get_option('maas-server'), maas_oauth)
    manager = MAASAccount(*args)
    try:
        manager.login()
    except subprocess.CalledProcessError:
        log.info("Could not login with MAAS 2.0 API, trying 1.0")
        manager = MAAS1Account(*args)
        manager.login()
    yield manager
    # We do not call manager.logout() because it can break concurrent procs.


def get_config(boot_config):
    config = boot_config.make_config_copy()
    if boot_config.provider not in ('lxd', 'manual'):
        config.update(boot_config.get_cloud_credentials())
    return config


def start_libvirt_domain(uri, domain):
    """Call virsh to start the domain.

    @Parms URI: The address of the libvirt service.
    @Parm domain: The name of the domain.
    """

    command = ['virsh', '-c', uri, 'start', domain]
    try:
        subprocess.check_output(command, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e:
        if 'already active' in e.output:
            return '%s is already running; nothing to do.' % domain
        raise Exception('%s failed:\n %s' % (command, e.output))
    sleep(30)
    for ignored in until_timeout(120):
        if verify_libvirt_domain(uri, domain, LIBVIRT_DOMAIN_RUNNING):
            return "%s is now running" % domain
        sleep(2)
    raise Exception('libvirt domain %s did not start.' % domain)


def stop_libvirt_domain(uri, domain):
    """Call virsh to shutdown the domain.

    @Parms URI: The address of the libvirt service.
    @Parm domain: The name of the domain.
    """

    command = ['virsh', '-c', uri, 'shutdown', domain]
    try:
        subprocess.check_output(command, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as e:
        if 'domain is not running' in e.output:
            return ('%s is not running; nothing to do.' % domain)
        raise Exception('%s failed:\n %s' % (command, e.output))
    sleep(30)
    for ignored in until_timeout(120):
        if verify_libvirt_domain(uri, domain, LIBVIRT_DOMAIN_SHUT_OFF):
            return "%s is now shut off" % domain
        sleep(2)
    raise Exception('libvirt domain %s is not shut off.' % domain)


def verify_libvirt_domain(uri, domain, state=LIBVIRT_DOMAIN_RUNNING):
    """Returns a bool based on if the domain is in the given state.

    @Parms URI: The address of the libvirt service.
    @Parm domain: The name of the domain.
    @Parm state: The state to verify (e.g. "running or "shut off").
    """

    dom_status = get_libvirt_domstate(uri, domain)
    return state in dom_status


def get_libvirt_domstate(uri, domain):
    """Call virsh to get the state of the given domain.

    @Parms URI: The address of the libvirt service.
    @Parm domain: The name of the domain.
    """

    command = ['virsh', '-c', uri, 'domstate', domain]
    try:
        sub_output = subprocess.check_output(command)
    except subprocess.CalledProcessError:
        raise Exception('%s failed' % command)
    return sub_output


def parse_euca(euca_output):
    for line in euca_output.splitlines():
        fields = line.split('\t')
        if fields[0] != 'INSTANCE':
            continue
        yield fields[1], fields[3]


def describe_instances(instances=None, running=False, job_name=None,
                       env=None):
    command = ['euca-describe-instances']
    if job_name is not None:
        command.extend(['--filter', 'tag:job_name=%s' % job_name])
    if running:
        command.extend(['--filter', 'instance-state-name=running'])
    if instances is not None:
        command.extend(instances)
    log.info(' '.join(command))
    return parse_euca(subprocess.check_output(command, env=env))


def get_job_instances(job_name):
    description = describe_instances(job_name=job_name, running=True)
    return (machine_id for machine_id, name in description)


def destroy_job_instances(job_name):
    instances = list(get_job_instances(job_name))
    if len(instances) == 0:
        return
    subprocess.check_call(['euca-terminate-instances'] + instances)


def resolve_remote_dns_names(env, remote_machines):
    """Update addresses of given remote_machines as needed by providers."""
    if env.provider != 'maas':
        # Only MAAS requires special handling at prsent.
        return
    # MAAS hostnames are not resolvable, but we can adapt them to IPs.
    with maas_account_from_boot_config(env) as account:
        allocated_ips = account.get_allocated_ips()
    for remote in remote_machines:
        if remote.get_address() in allocated_ips:
            remote.update_address(allocated_ips[remote.address])
