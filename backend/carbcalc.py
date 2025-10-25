def calculate_from_maf(maf_gs: float):
    """
    Estimate CO₂ emissions using MAF (grams/second).
    """
    # MAF to fuel rate conversion
    afr = 14.7  # Air-Fuel Ratio for gasoline
    fuel_density = 720  # g/L
    fuel_gs = maf_gs / afr
    fuel_lph = (fuel_gs / fuel_density) * 3600
    co2_kgph = fuel_lph * 2.31
    return {"co2_kg_per_hr": co2_kgph, "fuel_lph": fuel_lph}


def calculate_from_fuel_rate(fuel_lph: float):
    """
    Estimate CO₂ directly from fuel rate (L/h).
    """
    co2_kgph = fuel_lph * 2.31  # gasoline conversion factor
    return {"co2_kg_per_hr": co2_kgph, "fuel_lph": fuel_lph}
