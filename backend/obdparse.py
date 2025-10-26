def parse_obd_response(response: str):
    """
    Parses OBD-II hex response strings like:
    41 0C 1A F8  -> Engine RPM
    41 04 5A     -> Engine Load
    41 0B 3C     -> Intake Manifold Pressure
    41 0D 28     -> Vehicle Speed
    41 5E 02 1C  -> Fuel Rate
    """
    try:
        parts = response.strip().split()
        if len(parts) < 3:
            return None

        mode = parts[0].upper()
        pid = parts[1].upper()

        if mode != "41":
            return None  # Only live sensor data

        # Engine RPM (0C)  -> ((A*256)+B)/4
        if pid == "0C" and len(parts) >= 4:
            A, B = int(parts[2], 16), int(parts[3], 16)
            rpm = ((A * 256) + B) / 4
            return {"pid": "010C", "label": "Engine RPM", "value": float(rpm), "unit": "rpm"}

        # Vehicle Speed (0D)  -> A
        if pid == "0D":
            A = int(parts[2], 16)
            return {"pid": "010D", "label": "Vehicle Speed", "value": float(A), "unit": "km/h"}

        # Engine Load (04) -> A * 100 / 255
        if pid == "04":
            A = int(parts[2], 16)
            load = (A * 100) / 255
            return {"pid": "0104", "label": "Engine Load", "value": float(load), "unit": "%"}

        # Intake Manifold Pressure (0B) -> A
        if pid == "0B":
            A = int(parts[2], 16)
            return {"pid": "010B", "label": "Intake Manifold Pressure", "value": float(A), "unit": "kPa"}

        # Fuel Rate (5E) -> ((A*256)+B)/20 L/h
        if pid == "5E" and len(parts) >= 4:
            A, B = int(parts[2], 16), int(parts[3], 16)
            fuel_rate = ((A * 256) + B) / 20
            return {"pid": "015E", "label": "Fuel Rate", "value": float(fuel_rate), "unit": "L/h"}

        return None

    except Exception as e:
        print(f"⚠️ Parse error: {e}")
        return None
