from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from obdparse import parse_obd_response
from carbcalc import calculate_from_fuel_rate, calculate_from_speed_rpm_load

app = FastAPI(title="Car-bon Backend API")


class OBDPayload(BaseModel):
    rpm_hex: Optional[str] = None
    engine_load_hex: Optional[str] = None
    intake_manifold_hex: Optional[str] = None
    speed_kmh: Optional[float] = None
    timestamp: Optional[str] = None


@app.post("/obd-data")
async def receive_obd_data(payload: OBDPayload):
    timestamp = payload.timestamp or datetime.utcnow().isoformat()
    print(f"\n[{timestamp}] 🚗 Received OBD hex data + speed: {payload.dict()}")

    # Parse OBD responses
    parsed_data = {}
    if payload.rpm_hex:
        parsed_data["rpm"] = parse_obd_response(payload.rpm_hex)
    if payload.engine_load_hex:
        parsed_data["engine_load"] = parse_obd_response(payload.engine_load_hex)
    if payload.intake_manifold_hex:
        parsed_data["intake_manifold"] = parse_obd_response(payload.intake_manifold_hex)

    # Extract or fallback values
    rpm_value = parsed_data.get("rpm", {}).get("value", 2000.0)          # assume idle if missing
    load_value = parsed_data.get("engine_load", {}).get("value", 30.0)   # assume light load
    speed_value = payload.speed_kmh if payload.speed_kmh is not None else 0.0

    # Calculate emissions if speed provided
    emissions = None
    if speed_value > 0:
        emissions = calculate_from_speed_rpm_load(speed_value, rpm_value, load_value)
        print(f"🌍 CO₂ Estimation (Speed+RPM+Load): {emissions}")
    else:
        print("⚠️ No speed value provided, skipping CO₂ calc")

    return {
        "ok": True,
        "parsed": parsed_data,
        "speed_kmh": speed_value,
        "emissions": emissions,
        "timestamp": timestamp
    }
