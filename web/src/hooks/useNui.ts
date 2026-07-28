import { useEffect, useRef } from 'react'

export async function fetchNui<T = unknown>(event: string, data?: unknown): Promise<T> {
  const res = await fetch(`https://zfishing/${event}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data ?? {}),
  })
  return res.json().catch(() => ({} as T))
}

export function useNuiEvent(handler: (msg: any) => void) {
  const saved = useRef(handler)
  saved.current = handler
  useEffect(() => {
    const listener = (e: MessageEvent) => saved.current(e.data)
    window.addEventListener('message', listener)
    return () => window.removeEventListener('message', listener)
  }, [])
}
