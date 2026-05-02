export interface SystemdService {
  name: string;
  load: string;
  active: string;
  sub: string;
  description: string;
}

export type SystemdServiceSortKey = 'name' | 'status';
export type SortDirection = 'asc' | 'desc';

export interface SystemdServiceSort {
  key: SystemdServiceSortKey;
  direction: SortDirection;
}

export function sortSystemdServices(
  services: SystemdService[],
  sort: SystemdServiceSort,
): SystemdService[] {
  const direction = sort.direction === 'asc' ? 1 : -1;

  return [...services].sort((a, b) => {
    const primaryA = sort.key === 'name' ? a.name : `${a.active} ${a.sub}`;
    const primaryB = sort.key === 'name' ? b.name : `${b.active} ${b.sub}`;
    const primary = primaryA.localeCompare(primaryB, undefined, { sensitivity: 'base' });

    if (primary !== 0) {
      return primary * direction;
    }

    return a.name.localeCompare(b.name, undefined, { sensitivity: 'base' });
  });
}
