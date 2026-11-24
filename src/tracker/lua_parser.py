"""Pure-Python Lua SavedVariables parser and WoW addon dump normalizer."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping

from .config import NormalizedLot, ScanType


class LuaParseError(ValueError):
    """Raised when a Lua SavedVariables file cannot be parsed."""


class _LuaParser:
    """Recursive-descent parser for Lua table/literal SavedVariables assignments."""

    def __init__(self, text: str) -> None:
        self.text = text
        self.length = len(text)
        self.pos = 0

    def parse_file(self) -> dict[str, Any]:
        result: dict[str, Any] = {}
        self._skip_ws_and_comments()
        while self.pos < self.length:
            if self.text.startswith("local ", self.pos):
                self.pos += 6
                self._skip_ws_and_comments()
            ident = self._read_identifier()
            self._skip_ws_and_comments()
            self._expect("=")
            self._skip_ws_and_comments()
            value = self._parse_value()
            result[ident] = value
            self._skip_ws_and_comments()
            if self.pos < self.length and self.text[self.pos] == ";":
                self.pos += 1
                self._skip_ws_and_comments()
        return result

    def _skip_ws_and_comments(self) -> None:
        while self.pos < self.length:
            ch = self.text[self.pos]
            if ch in " \t\r\n":
                self.pos += 1
                continue
            if self.text.startswith("--[[", self.pos):
                end = self.text.find("]]", self.pos + 4)
                self.pos = self.length if end == -1 else end + 2
                continue
            if self.text.startswith("--", self.pos):
                end = self.text.find("\n", self.pos + 2)
                self.pos = self.length if end == -1 else end + 1
                continue
            break

    def _expect(self, char: str) -> None:
        if self.pos >= self.length or self.text[self.pos] != char:
            raise LuaParseError(f"Expected '{char}' at position {self.pos}")
        self.pos += 1

    def _read_identifier(self) -> str:
        start = self.pos
        if self.pos < self.length and (self.text[self.pos].isalpha() or self.text[self.pos] == "_"):
            self.pos += 1
            while self.pos < self.length and (self.text[self.pos].isalnum() or self.text[self.pos] == "_"):
                self.pos += 1
            return self.text[start : self.pos]
        raise LuaParseError(f"Expected identifier at position {self.pos}")

    def _parse_value(self) -> Any:
        self._skip_ws_and_comments()
        if self.pos >= self.length:
            raise LuaParseError("Unexpected end of input while parsing value")

        ch = self.text[self.pos]
        if ch == "{":
            return self._parse_table()
        if ch in ('"', "'"):
            return self._parse_string()
        if ch.isdigit() or (ch == "-" and self.pos + 1 < self.length and self.text[self.pos + 1].isdigit()):
            return self._parse_number()

        ident = self._read_identifier()
        if ident == "true":
            return True
        if ident == "false":
            return False
        if ident == "nil":
            return None
        return ident

    def _parse_string(self) -> str:
        quote = self.text[self.pos]
        self.pos += 1
        chars: list[str] = []
        escapes = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"', "'": "'"}
        while self.pos < self.length:
            ch = self.text[self.pos]
            if ch == quote:
                self.pos += 1
                return "".join(chars)
            if ch == "\\":
                self.pos += 1
                if self.pos >= self.length:
                    raise LuaParseError("Unterminated escape sequence")
                esc = self.text[self.pos]
                self.pos += 1
                chars.append(escapes.get(esc, esc))
            else:
                chars.append(ch)
                self.pos += 1
        raise LuaParseError("Unterminated string literal")

    def _parse_number(self) -> int | float:
        start = self.pos
        if self.text[self.pos] == "-":
            self.pos += 1
        while self.pos < self.length and (self.text[self.pos].isdigit() or self.text[self.pos] in ".eE+-"):
            if self.text[self.pos] in "+-" and self.text[self.pos - 1] not in "eE":
                break
            self.pos += 1
        raw = self.text[start : self.pos]
        if "." in raw or "e" in raw or "E" in raw:
            return float(raw)
        return int(raw)

    def _parse_table(self) -> dict[Any, Any] | list[Any]:
        self._expect("{")
        self._skip_ws_and_comments()

        array_items: list[Any] = []
        map_items: dict[Any, Any] = {}
        has_keys = False
        next_index = 1

        while self.pos < self.length:
            self._skip_ws_and_comments()
            if self.pos < self.length and self.text[self.pos] == "}":
                self.pos += 1
                break

            if self.text[self.pos] == "[":
                has_keys = True
                self.pos += 1
                self._skip_ws_and_comments()
                key = self._parse_value()
                self._skip_ws_and_comments()
                self._expect("]")
                self._skip_ws_and_comments()
                self._expect("=")
                val = self._parse_value()
                map_items[key] = val
            else:
                # Lookahead for `ident = value`
                saved_pos = self.pos
                is_kv = False
                if self.text[self.pos].isalpha() or self.text[self.pos] == "_":
                    key_ident = self._read_identifier()
                    self._skip_ws_and_comments()
                    if self.pos < self.length and self.text[self.pos] == "=":
                        is_kv = True
                        has_keys = True
                        self.pos += 1
                        val = self._parse_value()
                        map_items[key_ident] = val
                    else:
                        self.pos = saved_pos

                if not is_kv:
                    val = self._parse_value()
                    array_items.append(val)
                    map_items[next_index] = val
                    next_index += 1

            self._skip_ws_and_comments()
            if self.pos < self.length and self.text[self.pos] in (",", ";"):
                self.pos += 1

        if not has_keys:
            return array_items
        return map_items


def parse_lua_saved_variables(content: str) -> dict[str, Any]:
    """Parse a Lua SavedVariables string into Python dicts/lists."""
    return _LuaParser(content).parse_file()


@dataclass(frozen=True, slots=True)
class LuaImportResult:
    """Normalized result extracted from a SavedVariables file."""

    lots: list[NormalizedLot]
    scan_type: ScanType
    format_name: str
    meta: dict[str, Any]


def _extract_from_lot_dict(
    entry: Mapping[Any, Any],
    *,
    fallback_item_id: int | None = None,
    name_to_id: Mapping[str, int] | None = None,
) -> NormalizedLot | None:
    raw_id = entry.get("item_id") or entry.get("itemId") or entry.get("id") or fallback_item_id
    item_name = entry.get("name") or entry.get("item_name") or entry.get("itemName")

    if raw_id is None and isinstance(item_name, str) and name_to_id:
        raw_id = name_to_id.get(item_name.strip().lower())

    if raw_id is None:
        return None
    try:
        item_id = int(raw_id)
    except (TypeError, ValueError):
        return None

    qty = int(entry.get("quantity") or entry.get("count") or entry.get("stack") or entry.get("available") or 1)
    if qty <= 0:
        qty = 1

    unit_price = (
        entry.get("unit_price")
        or entry.get("unitPrice")
        or entry.get("minPrice")
        or entry.get("m")
        or entry.get("price")
    )
    if unit_price is None and entry.get("buyout") is not None:
        unit_price = int(entry["buyout"]) // qty

    if unit_price is None or int(unit_price) <= 0:
        return None

    return NormalizedLot(
        item_id=item_id,
        unit_price_copper=int(unit_price),
        quantity=qty,
        item_name=str(item_name) if item_name else None,
    )


def load_saved_variables(
    file_path: str | Path,
    *,
    scan_type: ScanType | None = None,
    name_to_id: Mapping[str, int] | None = None,
) -> LuaImportResult:
    """Parse a SavedVariables Lua file (`PriceLog.lua`, `Auctionator.lua`, or generic scanner)."""
    path = Path(file_path)
    content = path.read_text(encoding="utf-8")
    parsed = parse_lua_saved_variables(content)

    lots: list[NormalizedLot] = []
    detected_format = "generic"
    inferred_scan_type: ScanType = scan_type or "partial"

    # 1. PriceLog.lua style (`PriceLogDB` / `PriceLogData`)
    for key in ("PriceLogDB", "PriceLogData", "AuctionScannerDB"):
        if key in parsed and isinstance(parsed[key], dict):
            detected_format = key
            db_obj = parsed[key]
            if scan_type is None and db_obj.get("scan_type") in ("full", "partial"):
                inferred_scan_type = db_obj["scan_type"]
            elif scan_type is None and db_obj.get("isFullScan") is True:
                inferred_scan_type = "full"

            items_container = db_obj.get("items") or db_obj.get("auctions") or db_obj.get("lots") or db_obj
            if isinstance(items_container, list):
                for entry in items_container:
                    if isinstance(entry, dict):
                        lot = _extract_from_lot_dict(entry, name_to_id=name_to_id)
                        if lot:
                            lots.append(lot)
            elif isinstance(items_container, dict):
                for k, v in items_container.items():
                    if isinstance(v, dict):
                        fallback_id = int(k) if isinstance(k, int) or (isinstance(k, str) and k.isdigit()) else None
                        lot = _extract_from_lot_dict(v, fallback_item_id=fallback_id, name_to_id=name_to_id)
                        if lot:
                            lots.append(lot)
                    elif isinstance(v, list):
                        fallback_id = int(k) if isinstance(k, int) or (isinstance(k, str) and k.isdigit()) else None
                        for sub in v:
                            if isinstance(sub, dict):
                                lot = _extract_from_lot_dict(sub, fallback_item_id=fallback_id, name_to_id=name_to_id)
                                if lot:
                                    lots.append(lot)

    # 2. Auctionator.lua (`AUCTIONATOR_PRICE_DATABASE`)
    if not lots and "AUCTIONATOR_PRICE_DATABASE" in parsed and isinstance(parsed["AUCTIONATOR_PRICE_DATABASE"], dict):
        detected_format = "Auctionator"
        apdb = parsed["AUCTIONATOR_PRICE_DATABASE"]
        for _, realm_data in apdb.items():
            if not isinstance(realm_data, dict):
                continue
            for item_key, item_val in realm_data.items():
                if not isinstance(item_val, dict):
                    continue
                fallback_id: int | None = None
                item_name: str | None = None
                if isinstance(item_key, int):
                    fallback_id = item_key
                elif isinstance(item_key, str):
                    if item_key.isdigit():
                        fallback_id = int(item_key)
                    elif item_key.startswith("g:") or item_key.startswith("i:"):
                        tail = item_key.split(":")[-1]
                        if tail.isdigit():
                            fallback_id = int(tail)
                    else:
                        item_name = item_key
                        if name_to_id:
                            fallback_id = name_to_id.get(item_key.strip().lower())

                lot = _extract_from_lot_dict(
                    {**item_val, "name": item_name},
                    fallback_item_id=fallback_id,
                    name_to_id=name_to_id,
                )
                if lot:
                    lots.append(lot)

    # 3. Generic top-level list/dict export
    if not lots:
        for _, top_val in parsed.items():
            if isinstance(top_val, list):
                for entry in top_val:
                    if isinstance(entry, dict):
                        lot = _extract_from_lot_dict(entry, name_to_id=name_to_id)
                        if lot:
                            lots.append(lot)
            elif isinstance(top_val, dict):
                for k, v in top_val.items():
                    if isinstance(v, dict):
                        fallback_id = int(k) if isinstance(k, int) or (isinstance(k, str) and k.isdigit()) else None
                        lot = _extract_from_lot_dict(v, fallback_item_id=fallback_id, name_to_id=name_to_id)
                        if lot:
                            lots.append(lot)

    return LuaImportResult(
        lots=lots,
        scan_type=inferred_scan_type,
        format_name=detected_format,
        meta={"file_path": str(path), "format": detected_format, "lot_count": len(lots)},
    )
