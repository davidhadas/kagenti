// Copyright 2025 IBM Corp.
// Licensed under the Apache License, Version 2.0

import { useState, useEffect } from 'react';
import { useAuth } from '@/contexts';

export interface FeatureFlags {
  sandbox: boolean;
  integrations: boolean;
  triggers: boolean;
}

const DEFAULT_FLAGS: FeatureFlags = {
  sandbox: false,
  integrations: false,
  triggers: false,
};

let cachedFlags: FeatureFlags | null = null;

export function useFeatureFlags(): FeatureFlags {
  const { isAuthenticated, isEnabled, token } = useAuth();
  const [flags, setFlags] = useState<FeatureFlags>(cachedFlags ?? DEFAULT_FLAGS);

  useEffect(() => {
    // Wait for auth to complete before fetching (endpoint requires ROLE_VIEWER)
    if (cachedFlags || !isAuthenticated || !token) return;
    const controller = new AbortController();
    fetch('/api/v1/config/features', {
      signal: controller.signal,
      headers: { Authorization: `Bearer ${token}` },
    })
      .then(res => res.ok ? res.json() : DEFAULT_FLAGS)
      .then((data) => {
        const validated: FeatureFlags = {
          sandbox: data.sandbox === true,
          integrations: data.integrations === true,
          triggers: data.triggers === true,
        };
        cachedFlags = validated;
        setFlags(validated);
      })
      .catch((e) => { if (e?.name !== 'AbortError') console.debug('Feature flags fetch failed:', e); });
    return () => controller.abort();
  }, [isAuthenticated, token]);

  // When auth is disabled, fetch without token (public fallback)
  useEffect(() => {
    if (cachedFlags || isEnabled) return;
    const controller = new AbortController();
    fetch('/api/v1/config/features', { signal: controller.signal })
      .then(res => res.ok ? res.json() : DEFAULT_FLAGS)
      .then((data) => {
        const validated: FeatureFlags = {
          sandbox: data.sandbox === true,
          integrations: data.integrations === true,
          triggers: data.triggers === true,
        };
        cachedFlags = validated;
        setFlags(validated);
      })
      .catch((e) => { if (e?.name !== 'AbortError') console.debug('Feature flags fetch failed:', e); });
    return () => controller.abort();
  }, [isEnabled]);

  return flags;
}
