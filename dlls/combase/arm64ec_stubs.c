#include <stdarg.h>

#include "windef.h"
#include "winbase.h"

#ifdef __arm64ec__
static HRESULT WINAPI combase_stub(void)
{
    SetLastError(ERROR_CALL_NOT_IMPLEMENTED);
    return E_NOTIMPL;
}

HRESULT WINAPI __wine_stub_HSTRING_UserFree64(void)                 { return combase_stub(); }
HRESULT WINAPI __wine_stub_HSTRING_UserMarshal64(void)              { return combase_stub(); }
HRESULT WINAPI __wine_stub_HSTRING_UserSize64(void)                 { return combase_stub(); }
HRESULT WINAPI __wine_stub_HSTRING_UserUnmarshal64(void)            { return combase_stub(); }
HRESULT WINAPI __wine_stub_WdtpInterfacePointer_UserFree64(void)    { return combase_stub(); }
HRESULT WINAPI __wine_stub_WdtpInterfacePointer_UserMarshal64(void) { return combase_stub(); }
HRESULT WINAPI __wine_stub_WdtpInterfacePointer_UserSize64(void)    { return combase_stub(); }
HRESULT WINAPI __wine_stub_WdtpInterfacePointer_UserUnmarshal64(void){ return combase_stub(); }
#endif
