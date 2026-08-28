from pyproj import Transformer
from typing import Tuple

# Create transformers for coordinate conversion
# EPSG:4326 is WGS84 (lat/lon)
# EPSG:3857 is Web Mercator
wgs84_to_mercator = Transformer.from_crs("EPSG:4326", "EPSG:3857", always_xy=True)
mercator_to_wgs84 = Transformer.from_crs("EPSG:3857", "EPSG:4326", always_xy=True)


def transform_to_mercator(longitude: float, latitude: float):
    """
    Convert longitude and latitude (WGS84) to Web Mercator coordinates (EPSG:3857).
    
    Args:
        longitude (float): Longitude in degrees, must be between -180 and 180
        latitude (float): Latitude in degrees, must be between -90 and 90

    Returns:
        Tuple[float, float]: (x, y) coordinates in Web Mercator projection in meters

    Note:
        The Web Mercator projection is used for web mapping applications and has
        limitations near the poles. Coordinates are returned in meters from the
        projection origin.
    """
    x, y = wgs84_to_mercator.transform(longitude, latitude)
    return x, y


def get_spatial_partition(x: float, y: float, cell_length: int) -> Tuple[int, int]:
    """
    Get the spatial partition (grid cell coordinates) for given x and y coordinates in mercator projection.
    
    This function divides the Web Mercator projection into a regular grid and returns the grid cell
    coordinates for the given point. The grid starts at the Web Mercator projection bounds.

    Args:
        x (float): x coordinate in mercator projection (meters)
        y (float): y coordinate in mercator projection (meters)
        cell_length (int): Length of each grid cell in meters

    Returns:
        Tuple[int, int]: (x_cell, y_cell) coordinates of the grid cell
        
    Note:
        The grid origin is at (-20037508, -20037508) which corresponds to the
        Web Mercator projection bounds. Cell coordinates start from (0, 0).
    """
    # Web Mercator projection bounds (in meters)
    # These are the standard bounds for EPSG:3857 projection
    x_min = -20037508.34
    y_min = -20037508.34

    # Convert to cell coordinates using integer division
    x_cell = int((x - x_min) / cell_length)
    y_cell = int((y - y_min) / cell_length)
    
    
    return x_cell, y_cell 

if __name__ == "__main__":
    # Example usage and testing
    
    # City coordinates in (longitude, latitude) format (WGS84)
    city_coordinates = {
        "Makkah": (39.8262, 21.4225),
        "Riyadh": (46.6753, 24.7136),
        "Jeddah": (39.1925, 21.4858),
        "Dammam": (50.0551, 26.4256),
        "Almadina": (39.6142, 24.4686)
    }
    
    # Pre-calculated Mercator coordinates (x, y) in meters for testing
    # These coordinates were converted from WGS84 (longitude, latitude) to Web Mercator
    city_coordinates_mercator = {
        "Makkah": (4433432.30, 2442329.09),
        "Jeddah": (4362889.14, 2449900.21),
        "Riyadh": (5195870.62, 2840607.62),
        "Dammam": (5572108.24, 3051889.53),
        "Almadina": (4409832.57, 2810613.91)
    }
    
    # Grid cell size: 50km x 50km squares
    side_length = 500000  # 50,000 meters
    
    print("Spatial Partitioning Example:")
    print("=" * 50)
    
    # Demonstrate the full workflow: WGS84 -> Mercator -> Spatial Partition
    for city, (x, y) in city_coordinates_mercator.items():
        # Step 1: Convert WGS84 to Web Mercator
        # x, y = transform_to_mercator(lon, lat)
        
        # Step 2: Get spatial partition
        x_cell, y_cell = get_spatial_partition(x, y, side_length)
        
        print(f"{city}:")
        print(f"  Mercator: ({x:.2f}, {y:.2f})")
        print(f"  Grid Cell: ({x_cell}, {y_cell})")
        print()
