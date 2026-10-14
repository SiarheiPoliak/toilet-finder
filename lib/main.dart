import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const ToiletFinderApp());
}

class ToiletFinderApp extends StatelessWidget {
  const ToiletFinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Toilet Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const MapScreen(),
    );
  }
}

// Data model representing a single toilet point from OpenStreetMap
class ToiletNode {
  final int id;
  final LatLng position;
  final String name;
  final bool? isPaid;
  final String charge;
  final String openingHours;
  final String access;
  final String wheelchair;

  ToiletNode({
    required this.id,
    required this.position,
    required this.name,
    required this.isPaid,
    required this.charge,
    required this.openingHours,
    required this.access,
    required this.wheelchair,
  });

  factory ToiletNode.fromJson(Map<String, dynamic> json) {
    final tags = (json['tags'] as Map<String, dynamic>?) ?? {};
    final double lat = (json['lat'] ?? json['center']?['lat'] ?? 0.0).toDouble();
    final double lon = (json['lon'] ?? json['center']?['lon'] ?? 0.0).toDouble();

    bool? paidStatus;
    final String? feeTag = tags['fee']?.toString().toLowerCase();
    final String? accessTag = tags['access']?.toString().toLowerCase();

    if (feeTag == 'yes' || tags.containsKey('charge') || accessTag == 'customers') {
      paidStatus = true;
    } else if (feeTag == 'no' || feeTag == 'none') {
      paidStatus = false;
    }

    return ToiletNode(
      id: json['id'] as int,
      position: LatLng(lat, lon),
      name: tags['name']?.toString() ?? 'Общественный туалет',
      isPaid: paidStatus,
      charge: tags['charge']?.toString() ?? 'Не указана',
      openingHours: tags['opening_hours']?.toString() ?? 'Не указаны',
      access: tags['access']?.toString() ?? 'Общедоступный',
      wheelchair: tags['wheelchair']?.toString() ?? 'Нет данных',
    );
  }
}

enum FilterType { all, freeOnly, paidOnly }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  
  LatLng _currentPosition = const LatLng(36.8841, 30.7056);
  LatLng? _lastFetchedPosition;
  
  List<ToiletNode> _allToilets = [];
  FilterType _selectedFilter = FilterType.all;
  
  bool _isLoading = false;
  bool _followUser = true;
  String _statusMessage = 'Определение геопозиции...';
  
  StreamSubscription<Position>? _positionStream;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _initLocationTracking();
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _debounceTimer?.cancel();
    super.dispose();
  }

  // Request GPS permissions and listen to real-time location changes
  Future<void> _initLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _statusMessage = 'Геолокация отключена. Загрузка по центру карты.';
      });
      _fetchToilets(_currentPosition);
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _statusMessage = 'Нет доступа к GPS. Загрузка по центру карты.';
        });
        _fetchToilets(_currentPosition);
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _statusMessage = 'Доступ к GPS заблокирован в настройках.';
      });
      _fetchToilets(_currentPosition);
      return;
    }

    final Position initialPos = await Geolocator.getCurrentPosition();
    _updateUserLocation(LatLng(initialPos.latitude, initialPos.longitude));

    const LocationSettings locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 25,
    );

    _positionStream = Geolocator.getPositionStream(
      locationSettings: locationSettings,
    ).listen((Position position) {
      _updateUserLocation(LatLng(position.latitude, position.longitude));
    });
  }

  void _updateUserLocation(LatLng newPos) {
    setState(() {
      _currentPosition = newPos;
    });

    if (_followUser) {
      _mapController.move(_currentPosition, _mapController.camera.zoom);
    }

    const Distance distance = Distance();
    if (_lastFetchedPosition == null ||
        distance.as(LengthUnit.Meter, _lastFetchedPosition!, newPos) > 150) {
      _fetchToilets(newPos);
    }
  }

  // Query Overpass API for toilets within 1500m radius
  Future<void> _fetchToilets(LatLng center) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _statusMessage = 'Обновление карты туалетов...';
    });

    _lastFetchedPosition = center;

    final String query = '''
      [out:json][timeout:15];
      (
        node["amenity"="toilets"](around:1500,${center.latitude},${center.longitude});
        way["amenity"="toilets"](around:1500,${center.latitude},${center.longitude});
      );
      out center;
    ''';

    try {
      final response = await http.post(
        Uri.parse('https://overpass-api.de/api/interpreter'),
        body: {'data': query},
      );

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        final List<dynamic> elements = data['elements'] ?? [];

        final List<ToiletNode> loaded = elements
            .map((e) => ToiletNode.fromJson(e as Map<String, dynamic>))
            .where((t) => t.position.latitude != 0.0 && t.position.longitude != 0.0)
            .toList();

        setState(() {
          _allToilets = loaded;
          _statusMessage = 'Найдено точек в радиусе 1.5 км: ${loaded.length}';
        });
      } else {
        setState(() {
          _statusMessage = 'Ошибка сервера карт: ${response.statusCode}';
        });
      }
    } catch (e) {
      setState(() {
        _statusMessage = 'Ошибка соединения при загрузке данных';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  List<ToiletNode> get _filteredToilets {
    switch (_selectedFilter) {
      case FilterType.freeOnly:
        return _allToilets.where((t) => t.isPaid == false).toList();
      case FilterType.paidOnly:
        return _allToilets.where((t) => t.isPaid == true).toList();
      case FilterType.all:
        return _allToilets;
    }
  }

  void _onMapMoved(MapEvent event) {
    if (event is MapEventMove && event.source != MapEventSource.mapController) {
      if (_followUser) {
        setState(() {
          _followUser = false;
        });
      }

      _debounceTimer?.cancel();
      _debounceTimer = Timer(const Duration(milliseconds: 900), () {
        _fetchToilets(_mapController.camera.center);
      });
    }
  }

  void _showToiletDetails(ToiletNode toilet) {
    String statusText = 'Статус оплаты не указан (обычно бесплатно)';
    if (toilet.isPaid == true) {
      statusText = 'Платный (или только для клиентов)';
    } else if (toilet.isPaid == false) {
      statusText = 'Бесплатный общественный';
    }

    showModalBottomSheet(
      context: context,
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                toilet.name,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              Text('Тип: $statusText'),
              const SizedBox(height: 6),
              Text('Стоимость: ${toilet.charge}'),
              const SizedBox(height: 6),
              Text('Доступ: ${toilet.access}'),
              const SizedBox(height: 6),
              Text('Часы работы: ${toilet.openingHours}'),
              const SizedBox(height: 6),
              Text('Доступность для колясок: ${toilet.wheelchair}'),
              const SizedBox(height: 6),
              Text(
                'Координаты: ${toilet.position.latitude.toStringAsFixed(5)}, ${toilet.position.longitude.toStringAsFixed(5)}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Закрыть'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Карта туалетов', style: TextStyle(fontSize: 18)),
        actions: [
          TextButton(
            onPressed: () {
              setState(() {
                _followUser = true;
              });
              _mapController.move(_currentPosition, 16.0);
              _fetchToilets(_currentPosition);
            },
            child: const Text('Моя геопозиция'),
          ),
          TextButton(
            onPressed: () => _fetchToilets(_mapController.camera.center),
            child: const Text('Обновить'),
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            color: Colors.grey.shade100,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildFilterButton('Все', FilterType.all),
                    const SizedBox(width: 8),
                    _buildFilterButton('Бесплатные', FilterType.freeOnly),
                    const SizedBox(width: 8),
                    _buildFilterButton('Платные', FilterType.paidOnly),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _statusMessage,
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                ),
              ],
            ),
          ),
          Expanded(
            child: FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: _currentPosition,
                initialZoom: 15.0,
                onMapEvent: _onMapMoved,
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.example.toilet_finder',
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: _currentPosition,
                      width: 44,
                      height: 24,
                      child: Container(
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: Colors.blue.shade800,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: const Text(
                          'ВЫ',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    ..._filteredToilets.map((toilet) {
                      Color markerColor = Colors.teal;
                      String label = 'WC';

                      if (toilet.isPaid == true) {
                        markerColor = Colors.deepOrange;
                        label = 'PAID';
                      } else if (toilet.isPaid == false) {
                        markerColor = Colors.green.shade700;
                        label = 'FREE';
                      }

                      return Marker(
                        point: toilet.position,
                        width: 48,
                        height: 26,
                        child: GestureDetector(
                          onTap: () => _showToiletDetails(toilet),
                          child: Container(
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: markerColor,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white, width: 1.5),
                            ),
                            child: Text(
                              label,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      );
                    }),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterButton(String label, FilterType type) {
    final bool isSelected = _selectedFilter == type;
    return Expanded(
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          backgroundColor: isSelected ? Colors.blueGrey.shade800 : Colors.white,
          foregroundColor: isSelected ? Colors.white : Colors.black87,
          padding: const EdgeInsets.symmetric(vertical: 8),
        ),
        onPressed: () {
          setState(() {
            _selectedFilter = type;
          });
        },
        child: Text(label, style: const TextStyle(fontSize: 12)),
      ),
    );
  }
}
