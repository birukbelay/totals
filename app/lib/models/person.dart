enum PersonType {
  friend,
  family,
  shop,
  restaurant,
  service,
  employer,
  other,
}

extension PersonTypeStorage on PersonType {
  String get storageValue => name;
}

PersonType personTypeFromStorage(String? value) {
  for (final type in PersonType.values) {
    if (type.storageValue == value?.trim().toLowerCase()) return type;
  }
  return PersonType.other;
}

enum PersonIdentifierKind {
  bankAccount,
  phone,
}

extension PersonIdentifierKindStorage on PersonIdentifierKind {
  String get storageValue {
    switch (this) {
      case PersonIdentifierKind.bankAccount:
        return 'bank_account';
      case PersonIdentifierKind.phone:
        return 'phone';
    }
  }
}

PersonIdentifierKind personIdentifierKindFromStorage(String? value) {
  return value == PersonIdentifierKind.phone.storageValue
      ? PersonIdentifierKind.phone
      : PersonIdentifierKind.bankAccount;
}

enum TransactionPersonSource {
  manual,
  automatic,
}

extension TransactionPersonSourceStorage on TransactionPersonSource {
  String get storageValue => name;
}

TransactionPersonSource transactionPersonSourceFromStorage(String? value) {
  return value == TransactionPersonSource.automatic.storageValue
      ? TransactionPersonSource.automatic
      : TransactionPersonSource.manual;
}

class Person {
  final int? id;
  final String name;
  final PersonType type;
  final String? note;

  /// Reserved for the future Telegram bot that sends repayment nudges.
  final String? telegramHandle;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Person({
    this.id,
    required this.name,
    this.type = PersonType.friend,
    this.note,
    this.telegramHandle,
    required this.createdAt,
    required this.updatedAt,
  });

  factory Person.fromDb(Map<String, dynamic> row) {
    final createdAt = DateTime.tryParse(row['createdAt'] as String? ?? '');
    final updatedAt = DateTime.tryParse(row['updatedAt'] as String? ?? '');
    final now = DateTime.now();
    return Person(
      id: row['id'] as int?,
      name: (row['name'] as String?) ?? '',
      type: personTypeFromStorage(row['type'] as String?),
      note: row['note'] as String?,
      telegramHandle: row['telegramHandle'] as String?,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? createdAt ?? now,
    );
  }

  factory Person.fromJson(Map<String, dynamic> json) {
    return Person.fromDb({
      ...json,
      'id': json['id'] is int ? json['id'] : null,
    });
  }

  Map<String, dynamic> toDb() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'type': type.storageValue,
      'note': note,
      'telegramHandle': telegramHandle,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toJson() => toDb();

  Person copyWith({
    int? id,
    String? name,
    PersonType? type,
    String? note,
    String? telegramHandle,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Person(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      note: note ?? this.note,
      telegramHandle: telegramHandle ?? this.telegramHandle,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class PersonIdentifier {
  final int? id;
  final int personId;
  final PersonIdentifierKind kind;

  /// Bank the account belongs to. Null for phone numbers and for accounts
  /// whose bank is unknown, which then match any bank.
  final int? bankId;
  final String value;
  final String valueCanonical;
  final DateTime createdAt;

  const PersonIdentifier({
    this.id,
    required this.personId,
    required this.kind,
    this.bankId,
    required this.value,
    required this.valueCanonical,
    required this.createdAt,
  });

  factory PersonIdentifier.fromDb(Map<String, dynamic> row) {
    return PersonIdentifier(
      id: row['id'] is int ? row['id'] as int : null,
      personId: (row['personId'] as num?)?.toInt() ?? 0,
      kind: personIdentifierKindFromStorage(row['kind'] as String?),
      bankId: (row['bankId'] as num?)?.toInt(),
      value: (row['value'] as String?) ?? '',
      valueCanonical: (row['valueCanonical'] as String?) ?? '',
      createdAt: DateTime.tryParse(row['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toDb() {
    return {
      if (id != null) 'id': id,
      'personId': personId,
      'kind': kind.storageValue,
      'bankId': bankId,
      'value': value,
      'valueCanonical': valueCanonical,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toJson() => toDb();
}

class TransactionPersonLink {
  final String transactionReference;
  final int personId;
  final TransactionPersonSource source;
  final DateTime createdAt;

  const TransactionPersonLink({
    required this.transactionReference,
    required this.personId,
    required this.source,
    required this.createdAt,
  });

  factory TransactionPersonLink.fromDb(Map<String, dynamic> row) {
    return TransactionPersonLink(
      transactionReference: (row['transactionReference'] as String?) ?? '',
      personId: (row['personId'] as num?)?.toInt() ?? 0,
      source: transactionPersonSourceFromStorage(row['source'] as String?),
      createdAt: DateTime.tryParse(row['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toDb() {
    return {
      'transactionReference': transactionReference,
      'personId': personId,
      'source': source.storageValue,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toJson() => toDb();
}
