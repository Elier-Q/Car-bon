from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime
from obdparse import parse_obd_response
from carbcalc import calculate_from_maf

app = FastAPI(title="Car-bon Backend API")

# Expect only hex_data (and optionally timestamp)
class OBDPayload(BaseModel):
    hex_data: str
    timestamp: str | None = None

@app.post("/obd-data")
async def receive_obd_data(payload: OBDPayload):
    """
    Receives BLE → HTTP OBD-II data from Swift OBDManager.
    Example payload:
    {
        "hex_data": "41 2F 7F",
        "timestamp": "2025-10-25T17:30:00Z"
    }
    """
    print(f"\n[{datetime.now().isoformat()}] 🚗 Received Raw={payload.hex_data}")

    # Parse the hex OBD-II response into structured info
    parsed = parse_obd_response(payload.hex_data)
    print(f"🧩 Parsed OBD data: {parsed}")

    # CO₂ estimation only if MAF PID is detected (0110)
    emissions = None
    if parsed and parsed.get("pid") == "0110":
        maf_val = parsed["value"]
        emissions = calculate_from_maf(maf_val)
        parsed.update(emissions)
        print(f"🌍 CO₂ Estimation: {emissions}")

    return {
        "ok": True,
        "raw": payload.hex_data,
        "parsed": parsed,
        "emissions": emissions,
    }
