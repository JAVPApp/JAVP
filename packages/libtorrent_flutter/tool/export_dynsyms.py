import lief
from pathlib import Path

pkg = Path(__file__).resolve().parents[1]
main = pkg / "prebuilt/android/arm64-v8a/liblibtorrent_flutter.so"
backup = pkg / "native-build/android-arm64/liblibtorrent_flutter.so.bak"

# Restore pristine, then export
main.write_bytes(backup.read_bytes())
binary = lief.parse(str(main))
assert binary is not None

print("lief", lief.__version__)
print("has add_exported_function", hasattr(binary, "add_exported_function"))
print("has add_dynamic_symbol", hasattr(binary, "add_dynamic_symbol"))

name = "_ZN10libtorrent13settings_pack7set_intEii"
sym = binary.get_symbol(name)
print("sym", sym)
print(
    "attrs",
    [x for x in dir(sym) if any(k in x.lower() for k in ("export", "dynamic", "bind", "vis"))],
)
print("binding", sym.binding, "value", hex(sym.value), "exported", getattr(sym, "exported", None))
print("dyn before", [s.name for s in binary.dynamic_symbols if "settings_pack7set_int" in s.name])

# Approach: add_exported_function(address, name)
if hasattr(binary, "add_exported_function"):
    for n in [
        "_ZN10libtorrent14session_handle14apply_settingsERKNS_13settings_packE",
        "_ZN10libtorrent14session_handle14apply_settingsEONS_13settings_packE",
        "_ZN10libtorrent13settings_pack7set_intEii",
        "_ZN10libtorrent13settings_pack8set_boolEib",
        "_ZN10libtorrent13settings_pack7set_strEiNSt6__ndk112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEE",
        "_ZN10libtorrent13settings_packD2Ev",
        "_ZN10libtorrent13settings_packC2ERKS0_",
        "_ZTVN10libtorrent13settings_packE",
    ]:
        s = binary.get_symbol(n)
        if s is None:
            print("missing", n)
            continue
        binary.add_exported_function(s.value, n)
        print("add_exported_function", n, hex(s.value))

binary.write(str(main))

binary2 = lief.parse(str(main))
print(
    "dyn after",
    [s.name for s in binary2.dynamic_symbols if "settings_pack7set_int" in s.name or "apply_settings" in s.name],
)
