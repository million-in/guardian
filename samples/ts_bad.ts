// @ts-ignore
export function readValue(input: any): string {
  const value = input as any;

  if (input) {
    if (input.ready) {
      if (input.ready.deep) {
        if (input.ready.deep.value) {
          return value;
        }
      }
    }
  }

  return "";
}
