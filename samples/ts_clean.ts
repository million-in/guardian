type User = {
  id: string;
  active: boolean;
};

export function isActiveUser(user: User): boolean {
  if (!user.active) {
    return false;
  }

  return true;
}
