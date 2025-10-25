from fastapi import FastAPI, Request
from datetime import datetime
from obdparse import parse_obd_response
from carbcalc import calculate_from_maf

app = FastAPI(title="Car-bon Backend API")

@app.post("/obd-data")
async def receive_obd_data(request: Request):
    """
    Receives BLE → HTTP OBD-II data.
    """
    data = await request.json()
    response = data.get("response", "").strip()
    print(f"[{datetime.now().isoformat()}] Received: {response}")

    parsed = parse_obd_response(response)
    if parsed and parsed.get("pid") == "0110":  # MAF → CO₂
        maf_val = parsed["value"]
        emissions = calculate_from_maf(maf_val)
        parsed.update(emissions)

    return {"ok": True, "raw": response, "parsed": parsed}
