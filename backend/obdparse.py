def parse_obd_response(response: str):
    """
    Parses OBD-II hex response strings like:
    41 0C 1A F8 (RPM)
    41 10 00 8F (MAF)
    41 5E 02 1C (Fuel Rate)
    """
    try:
        parts = response.strip().split()
        if len(parts) < 3:
            return None

        mode = parts[0].upper()
        pid = parts[1].upper()

        if mode == "41":  # Live sensor data
            if pid == "0C":  # Engine RPM
                A, B = int(parts[2], 16), int(parts[3], 16)
                rpm = ((A * 256) + B) / 4
                return {"pid": "010C", "label": "Engine RPM", "value": rpm, "unit": "rpm"}

            elif pid == "0D":  # Vehicle Speed
                A = int(parts[2], 16)
                return {"pid": "010D", "label": "Vehicle Speed", "value": A, "unit": "km/h"}

            elif pid == "10":  # MAF (Mass Air Flow)
                A, B = int(parts[2], 16), int(parts[3], 16)
                maf = ((A * 256) + B) / 100
                return {"pid": "0110", "label": "Mass Air Flow", "value": maf, "unit": "g/s"}

            elif pid == "2F":  # Fuel Level
                A = int(parts[2], 16)
                fuel = (A * 100) / 255
                return {"pid": "012F", "label": "Fuel Level", "value": fuel, "unit": "%"}

            elif pid == "5E":  # Fuel Rate
                A, B = int(parts[2], 16), int(parts[3], 16)
                fuel_rate = ((A * 256) + B) / 20  # L/h
                return {"pid": "015E", "label": "Fuel Rate", "value": fuel_rate, "unit": "L/h"}

        elif mode == "49":  # Vehicle information
            if pid == "02":  # VIN
                vin_bytes = [chr(int(b, 16)) for b in parts[3:] if len(b) == 2]
                return {"pid": "0902", "label": "VIN", "value": "".join(vin_bytes)}

        return None

    except Exception as e:
        print(f"⚠️ Parse error: {e}")
        return None
