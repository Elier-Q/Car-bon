# carbcalc.py

from typing import Optional, Dict, List

# ------------------------------
# Constants
# ------------------------------
FUEL_PROPERTIES = {
    "gasoline": {
        "afr": 14.7,              # Air-Fuel Ratio
        "density": 0.745,         # kg/L
        "co2_factor": 2.3477      # kg CO₂ / L
    },
    "diesel": {
        "afr": 14.5,
        "density": 0.832,
        "co2_factor": 2.6840
    },
    "ethanol": {
        "afr": 9.0,
        "density": 0.789,
        "co2_factor": 1.909
    },
    "electric": {
        # Grid emission factor (U.S. average)
        "grid_factor": 0.4        # kg CO₂ / kWh
    }
}


# ------------------------------
# Core Functions
# ------------------------------
def calculate_from_maf(maf_gps: float, fuel_type: str = "gasoline") -> Dict[str, float]:
    """
    Estimate instantaneous fuel consumption and CO₂ emissions
    from MAF (Mass Air Flow) readings.

    Args:
        maf_gps: Mass Air Flow in grams per second
        fuel_type: Fuel type ("gasoline", "diesel", "ethanol")

    Returns:
        dict with fuel_L_per_hour and co2_kg_per_hour
    """
    props = FUEL_PROPERTIES.get(fuel_type.lower(), FUEL_PROPERTIES["gasoline"])
    afr = props["afr"]
    density = props["density"]
    co2_factor = props["co2_factor"]

    # Fuel mass flow (g/s)
    fuel_mass_flow_gps = maf_gps / afr

    # Convert to L/h
    fuel_kg_per_s = fuel_mass_flow_gps / 1000.0
    fuel_L_per_s = fuel_kg_per_s / density
    fuel_L_per_hour = fuel_L_per_s * 3600.0

    # CO₂ per hour
    co2_kg_per_hour = fuel_L_per_hour * co2_factor

    return {
        "fuel_L_per_hour": fuel_L_per_hour,
        "co2_kg_per_hour": co2_kg_per_hour
    }


def calculate_from_fuel_rate(fuel_rate_Lph: float, fuel_type: str = "gasoline") -> Dict[str, float]:
    """
    Calculate CO₂ directly from a known fuel rate (L/h).
    """
    props = FUEL_PROPERTIES.get(fuel_type.lower(), FUEL_PROPERTIES["gasoline"])
    co2_factor = props["co2_factor"]

    co2_kg_per_hour = fuel_rate_Lph * co2_factor

    return {
        "fuel_L_per_hour": fuel_rate_Lph,
        "co2_kg_per_hour": co2_kg_per_hour
    }


def calculate_electric(energy_kWh: float, region_factor: Optional[float] = None) -> Dict[str, float]:
    """
    Estimate CO₂ emissions for electric vehicles using grid factor.
    """
    factor = region_factor or FUEL_PROPERTIES["electric"]["grid_factor"]
    co2_kg = energy_kWh * factor
    return {"energy_kWh": energy_kWh, "co2_kg": co2_kg}


# ------------------------------
# Aggregation Utility
# ------------------------------
def summarize_trip(samples: List[Dict], fuel_type: str = "gasoline") -> Dict[str, float]:
    """
    Summarize total CO₂ output and fuel usage across a trip.

    Each sample in `samples` should include either:
      - "maf_gps", OR
      - "fuel_rate_Lph"
      (optionally "speed_kph" and "dt")

    Returns:
        Total CO₂ (kg), fuel used (L), average speed (km/h), total time (s)
    """
    total_fuel_L = 0.0
    total_co2_kg = 0.0
    total_time_s = 0.0
    speed_sum = 0.0
    speed_count = 0

    for s in samples:
        dt = s.get("dt", 1.0)  # seconds between readings

        if "fuel_rate_Lph" in s:
            calc = calculate_from_fuel_rate(s["fuel_rate_Lph"], fuel_type)
        elif "maf_gps" in s:
            calc = calculate_from_maf(s["maf_gps"], fuel_type)
        else:
            continue

        # Convert L/h → L/s, then scale by dt
        fuel_L = calc["fuel_L_per_hour"] / 3600.0 * dt
        co2_kg = calc["co2_kg_per_hour"] / 3600.0 * dt

        total_fuel_L += fuel_L
        total_co2_kg += co2_kg
        total_time_s += dt

        if "speed_kph" in s:
            speed_sum += s["speed_kph"]
            speed_count += 1

    avg_speed = speed_sum / speed_count if speed_count else 0.0

    return {
        "total_fuel_L": total_fuel_L,
        "total_co2_kg": total_co2_kg,
        "trip_time_s": total_time_s,
        "avg_speed_kph": avg_speed
    }


# ------------------------------
# Example Usage
# ------------------------------
if __name__ == "__main__":
    data_samples = [
        {"maf_gps": 10.0, "speed_kph": 50, "dt": 1},
        {"maf_gps": 12.0, "speed_kph": 60, "dt": 1},
        {"maf_gps": 8.0,  "speed_kph": 40, "dt": 1},
    ]

    result = summarize_trip(data_samples, fuel_type="gasoline")
    print("Trip Summary:")
    print(f"  Fuel used: {result['total_fuel_L']:.3f} L")
    print(f"  CO₂ emitted: {result['total_co2_kg']:.3f} kg")
    print(f"  Avg speed: {result['avg_speed_kph']:.1f} km/h")
    print(f"  Duration: {result['trip_time_s']:.1f} s")
