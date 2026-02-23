#include <stdarg.h>

#include "windef.h"
#include "winbase.h"

#ifdef __arm64ec__
static HRESULT WINAPI adsldpc_stub(void)
{
    SetLastError(ERROR_CALL_NOT_IMPLEMENTED);
    return E_NOTIMPL;
}

HRESULT WINAPI __wine_stub_adsldpc_dll_1(void)   { return adsldpc_stub(); }
HRESULT WINAPI __wine_stub_adsldpc_dll_2(void)   { return adsldpc_stub(); }
HRESULT WINAPI __wine_stub_adsldpc_dll_56(void)  { return adsldpc_stub(); }
HRESULT WINAPI __wine_stub_adsldpc_dll_60(void)  { return adsldpc_stub(); }
HRESULT WINAPI __wine_stub_adsldpc_dll_139(void) { return adsldpc_stub(); }
HRESULT WINAPI __wine_stub_adsldpc_dll_140(void) { return adsldpc_stub(); }
HRESULT WINAPI __wine_stub_adsldpc_dll_141(void) { return adsldpc_stub(); }
#endif
