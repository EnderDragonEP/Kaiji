"""The sync password, kept in Windows Credential Manager: it's protected by your Windows sign-in
and never written to config.json or the database (so it isn't in backups either)."""
import ctypes
from ctypes import wintypes

TARGET = "Kaiji/PostgreSQL"
CRED_TYPE_GENERIC = 1
CRED_PERSIST_LOCAL_MACHINE = 2          # this PC and this Windows user; it doesn't roam
ERROR_NOT_FOUND = 1168


class CREDENTIAL(ctypes.Structure):
    _fields_ = [("Flags", wintypes.DWORD), ("Type", wintypes.DWORD),
                ("TargetName", wintypes.LPWSTR), ("Comment", wintypes.LPWSTR),
                ("LastWritten", wintypes.FILETIME), ("CredentialBlobSize", wintypes.DWORD),
                ("CredentialBlob", ctypes.POINTER(ctypes.c_ubyte)), ("Persist", wintypes.DWORD),
                ("AttributeCount", wintypes.DWORD), ("Attributes", ctypes.c_void_p),
                ("TargetAlias", wintypes.LPWSTR), ("UserName", wintypes.LPWSTR)]


_advapi = ctypes.WinDLL("advapi32", use_last_error=True)
_advapi.CredWriteW.argtypes = [ctypes.POINTER(CREDENTIAL), wintypes.DWORD]
_advapi.CredWriteW.restype = wintypes.BOOL
_advapi.CredReadW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                              ctypes.POINTER(ctypes.POINTER(CREDENTIAL))]
_advapi.CredReadW.restype = wintypes.BOOL
_advapi.CredDeleteW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD]
_advapi.CredDeleteW.restype = wintypes.BOOL
_advapi.CredFree.argtypes = [ctypes.c_void_p]
_advapi.CredFree.restype = None


def save(user, password, target=TARGET):
    blob = password.encode("utf-16-le")
    data = (ctypes.c_ubyte * max(len(blob), 1)).from_buffer_copy(blob or b"\0")
    cred = CREDENTIAL(Type=CRED_TYPE_GENERIC, TargetName=target, CredentialBlobSize=len(blob),
                      CredentialBlob=ctypes.cast(data, ctypes.POINTER(ctypes.c_ubyte)),
                      Persist=CRED_PERSIST_LOCAL_MACHINE, UserName=user)
    if not _advapi.CredWriteW(ctypes.byref(cred), 0):
        raise ctypes.WinError(ctypes.get_last_error())


def load(target=TARGET):
    """The saved password, or None."""
    found = ctypes.POINTER(CREDENTIAL)()
    if not _advapi.CredReadW(target, CRED_TYPE_GENERIC, 0, ctypes.byref(found)):
        error = ctypes.get_last_error()
        if error == ERROR_NOT_FOUND:
            return None
        raise ctypes.WinError(error)
    try:
        cred = found.contents
        if not cred.CredentialBlobSize:
            return ""
        return ctypes.string_at(cred.CredentialBlob, cred.CredentialBlobSize).decode("utf-16-le")
    finally:
        _advapi.CredFree(found)


def forget(target=TARGET):
    if not _advapi.CredDeleteW(target, CRED_TYPE_GENERIC, 0):
        error = ctypes.get_last_error()
        if error != ERROR_NOT_FOUND:
            raise ctypes.WinError(error)
