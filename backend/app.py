from fastapi import FastAPI
from pydantic import BaseModel
from datetime import datetime
from typing import Optional
from obdparse import parse_obd_response
from carbcalc import calculate_from_speed_rpm_load

app = FastAPI(title="Car-bon Backend API")


class OBDPayload(BaseModel):
    rpm_hex: Optional[str] = None
    engine_load_hex: Optional[str] = None
    intake_manifold_hex: Optional[str] = None
    speed_kmh: Optional[float] = None
    session_data: Optional[dict] = None
    timestamp: Optional[str] = None


@app.post("/obd-data")
async def receive_obd_data(payload: OBDPayload):
    timestamp = payload.timestamp or datetime.utcnow().isoformat()
    
    # Check if this is session data (arrays) or single reading
    if payload.session_data:
        print(f"\n[{timestamp}] 📊 Received SESSION data")
        return process_session(payload.session_data, timestamp)
    
    # Handle single reading (original behavior)
    print(f"\n[{timestamp}] 🚗 Received SINGLE reading")
    
    parsed_data = {}
    if payload.rpm_hex:
        parsed_data["rpm"] = parse_obd_response(payload.rpm_hex)
    if payload.engine_load_hex:
        parsed_data["engine_load"] = parse_obd_response(payload.engine_load_hex)
    if payload.intake_manifold_hex:
        parsed_data["intake_manifold"] = parse_obd_response(payload.intake_manifold_hex)

    rpm = parsed_data.get("rpm", {}).get("value", 0)
    load = parsed_data.get("engine_load", {}).get("value", 0)
    speed = payload.speed_kmh or 0

    emissions = None
    if rpm > 0 and load > 0:
        emissions = calculate_from_speed_rpm_load(speed, rpm, load)
        print(f"🌍 Emissions: {emissions}")

    return {
        "ok": 1,
        "parsed": parsed_data,
        "speed_kmh": speed,
        "emissions": emissions,
        "timestamp": timestamp
    }


def process_session(session: dict, timestamp: str):
    """Parse all hex samples and return averages + emissions"""
    
    try:
        rpm_array = session.get("rpm_hex_array", [])
        load_array = session.get("engine_load_hex_array", [])
        speed_array = session.get("speed_hex_array", [])
        
        print(f"📊 Processing {len(rpm_array)} samples...")
        
        # Parse all samples
        rpm_vals = []
        for h in rpm_array:
            parsed = parse_obd_response(h)
            if parsed and "value" in parsed:
                rpm_vals.append(parsed["value"])
        
        load_vals = []
        for h in load_array:
            parsed = parse_obd_response(h)
            if parsed and "value" in parsed:
                load_vals.append(parsed["value"])
        
        speed_vals = []
        for h in speed_array:
            parsed = parse_obd_response(h)
            if parsed and "value" in parsed:
                speed_vals.append(parsed["value"])
        
        print(f"✅ Parsed: {len(rpm_vals)} RPM, {len(load_vals)} Load, {len(speed_vals)} Speed")
        
        if not rpm_vals or not load_vals:
            return {"ok": 0, "error": "No valid samples"}
        
        # Calculate averages
        avg_rpm = sum(rpm_vals) / len(rpm_vals)
        avg_load = sum(load_vals) / len(load_vals)
        avg_speed = sum(speed_vals) / len(speed_vals) if speed_vals else 0
        
        print(f"📊 Averages: RPM={avg_rpm:.0f}, Load={avg_load:.1f}%, Speed={avg_speed:.1f} km/h")
        
        # Calculate emissions from averages
        emissions = calculate_from_speed_rpm_load(avg_speed, avg_rpm, avg_load)
        print(f"🌍 Emissions: {emissions}")
        
        return {
            "ok": 1,
            "sample_count": len(rpm_vals),
            "averages": {
                "rpm": round(avg_rpm, 1),
                "engine_load": round(avg_load, 1),
                "speed": round(avg_speed, 1)
            },
            "emissions": emissions,
            "timestamp": timestamp
        }
        
    except Exception as e:
        print(f"❌ Error: {e}")
        import traceback
        traceback.print_exc()
        return {"ok": 0, "error": str(e)}


@app.get("/")
async def root():
    return {"service": "Car-bon Backend API", "status": "running"}
