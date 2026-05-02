import { describe, expect, it } from 'vitest';
import {
  sortSystemdServices,
  type SystemdService,
} from '../lib/system-monitor-utils';

const services: SystemdService[] = [
  {
    name: 'ssh.service',
    load: 'loaded',
    active: 'active',
    sub: 'running',
    description: 'OpenSSH server',
  },
  {
    name: 'ufw.service',
    load: 'loaded',
    active: 'inactive',
    sub: 'dead',
    description: 'Uncomplicated firewall',
  },
  {
    name: 'cron.service',
    load: 'loaded',
    active: 'active',
    sub: 'running',
    description: 'Regular background program processing daemon',
  },
];

describe('sortSystemdServices', () => {
  it('sorts services by name', () => {
    expect(
      sortSystemdServices(services, { key: 'name', direction: 'asc' }).map((service) => service.name),
    ).toEqual(['cron.service', 'ssh.service', 'ufw.service']);
  });

  it('sorts services by status and then service name', () => {
    expect(
      sortSystemdServices(services, { key: 'status', direction: 'desc' }).map((service) => service.name),
    ).toEqual(['ufw.service', 'cron.service', 'ssh.service']);
  });
});
