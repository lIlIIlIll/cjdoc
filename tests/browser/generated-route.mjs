// Use only for a destination known to be a generated declaration body.
export function declarationUrl(value, base) {
  const url = new URL(value, base);
  if (url.protocol === 'http:' || url.protocol === 'https:') {
    url.pathname = url.pathname.replace(/\/index[.]html$/, '/');
  }
  return url.href;
}
