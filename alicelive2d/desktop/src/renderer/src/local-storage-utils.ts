export function resolveStorageValue(currentValue, nextValue, filter) {
  const valueToStore = typeof nextValue === "function"
    ? nextValue(currentValue)
    : nextValue;

  return {
    valueToStore,
    filteredValue: filter ? filter(valueToStore) : valueToStore,
  };
}
