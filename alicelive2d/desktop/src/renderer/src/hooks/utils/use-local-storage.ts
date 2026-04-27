import { useCallback, useEffect, useRef, useState } from 'react';
import { resolveStorageValue } from '@/local-storage-utils.ts';

export function useLocalStorage<T>(
  key: string,
  initialValue: T,
  options?: {
    filter?: (value: T) => T
  },
) {
  const filterRef = useRef(options?.filter);
  const [storedValue, setStoredValue] = useState<T>(() => {
    try {
      const item = window.localStorage.getItem(key);
      const parsedValue = item ? JSON.parse(item) : initialValue;
      return parsedValue;
    } catch (error) {
      console.error(`Error reading localStorage key "${key}":`, error);
      return initialValue;
    }
  });

  useEffect(() => {
    filterRef.current = options?.filter;
  }, [options?.filter]);

  const setValue = useCallback((value: T | ((val: T) => T)) => {
    setStoredValue((currentValue) => {
      try {
        const { valueToStore, filteredValue } = resolveStorageValue(
          currentValue,
          value,
          filterRef.current,
        );
        window.localStorage.setItem(key, JSON.stringify(filteredValue));
        return valueToStore;
      } catch (error) {
        console.error(`Error setting localStorage key "${key}":`, error);
        return currentValue;
      }
    });
  }, [key]);

  return [storedValue, setValue] as const;
}
