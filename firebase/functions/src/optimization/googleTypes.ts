/**
 * Subset of the Route Optimization API v1 REST types used here
 * (https://developers.google.com/maps/documentation/route-optimization/reference/rest).
 * Durations are protobuf Duration strings ("123s"); timestamps are RFC 3339. Proto3 JSON omits
 * default values, so e.g. `shipmentIndex: 0` may be absent — labels are used for mapping.
 */
export interface LatLng { latitude: number; longitude: number }
export interface Waypoint { location?: { latLng: LatLng }; placeId?: string }

export interface TimeWindowApi {
  startTime?: string;
  endTime?: string;
  softEndTime?: string;
  costPerHourAfterSoftEndTime?: number;
}

export interface VisitRequestApi {
  arrivalWaypoint: Waypoint;
  duration?: string;
  timeWindows?: TimeWindowApi[];
  label?: string;
}

export interface ShipmentApi {
  label: string;
  deliveries: VisitRequestApi[];
  /** Intentionally never set: without a penalty cost a shipment is mandatory. */
  penaltyCost?: never;
}

export interface BreakRequestApi { earliestStartTime: string; latestStartTime: string; minDuration: string }

export interface VehicleApi {
  label: string;
  travelMode: "DRIVING";
  startWaypoint: Waypoint;
  endWaypoint?: Waypoint;
  costPerHour: number;
  costPerKilometer: number;
  startTimeWindows?: TimeWindowApi[];
  breakRule?: { breakRequests: BreakRequestApi[] };
}

export interface OptimizeToursRequest {
  timeout: string;
  model: {
    globalStartTime: string;
    globalEndTime: string;
    shipments: ShipmentApi[];
    vehicles: VehicleApi[];
  };
  considerRoadTraffic: boolean;
  populatePolylines: boolean;
  injectedSolutionConstraint?: {
    routes: Array<{ vehicleIndex: number; visits: Array<{ shipmentIndex: number; isPickup: false }> }>;
    constraintRelaxations: Array<{ relaxations: Array<{ level: string; thresholdVisitCount: number }>; vehicleIndices: number[] }>;
  };
  label: string;
}

export interface VisitApi { shipmentIndex?: number; isPickup?: boolean; startTime?: string; shipmentLabel?: string }
export interface TransitionApi {
  travelDuration?: string;
  travelDistanceMeters?: number;
  waitDuration?: string;
  breakDuration?: string;
  startTime?: string;
}
export interface RouteMetricsApi {
  performedShipmentCount?: number;
  travelDuration?: string;
  waitDuration?: string;
  breakDuration?: string;
  visitDuration?: string;
  totalDuration?: string;
  travelDistanceMeters?: number;
}
export interface ShipmentRouteApi {
  vehicleIndex?: number;
  vehicleStartTime?: string;
  vehicleEndTime?: string;
  visits?: VisitApi[];
  transitions?: TransitionApi[];
  routePolyline?: { points?: string };
  breaks?: Array<{ startTime?: string; duration?: string }>;
  metrics?: RouteMetricsApi;
}
export interface SkippedShipmentApi { index?: number; label?: string; reasons?: Array<{ code?: string }> }
export interface OptimizeToursResponse {
  routes?: ShipmentRouteApi[];
  skippedShipments?: SkippedShipmentApi[];
  validationErrors?: Array<{ code?: number; displayName?: string; errorMessage?: string }>;
  metrics?: { skippedMandatoryShipmentCount?: number };
}
