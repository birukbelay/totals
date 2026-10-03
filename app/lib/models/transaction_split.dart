enum TransactionSplitKind {
  /// Part of the payment that was the user's own spending in a category.
  expense,

  /// Part of the payment lent to a person.
  loan,

  /// A person's share of a bill the user paid for everyone.
  billShare,
}

extension TransactionSplitKindStorage on TransactionSplitKind {
  String get storageValue {
    switch (this) {
      case TransactionSplitKind.expense:
        return 'expense';
      case TransactionSplitKind.loan:
        return 'loan';
      case TransactionSplitKind.billShare:
        return 'bill_share';
    }
  }

  /// Loans and bill shares are owed back by a person.
  bool get isOwedByPerson => this != TransactionSplitKind.expense;
}

TransactionSplitKind transactionSplitKindFromStorage(String? value) {
  for (final kind in TransactionSplitKind.values) {
    if (kind.storageValue == value?.trim().toLowerCase()) return kind;
  }
  return TransactionSplitKind.expense;
}

enum TransactionSplitStatus {
  pending,
  paid,
}

extension TransactionSplitStatusStorage on TransactionSplitStatus {
  String get storageValue => name;
}

TransactionSplitStatus? transactionSplitStatusFromStorage(String? value) {
  for (final status in TransactionSplitStatus.values) {
    if (status.storageValue == value?.trim().toLowerCase()) return status;
  }
  return null;
}

/// One part of a parent transaction. Splits re-attribute the parent amount
/// to categories or people; they never change balances or totals.
class TransactionSplit {
  final int? id;
  final String parentReference;
  final double amount;
  final int? categoryId;
  final int? personId;
  final TransactionSplitKind kind;

  /// Only set for [TransactionSplitKind.isOwedByPerson] splits.
  final TransactionSplitStatus? status;
  final String? note;
  final DateTime createdAt;
  final DateTime updatedAt;

  const TransactionSplit({
    this.id,
    required this.parentReference,
    required this.amount,
    this.categoryId,
    this.personId,
    this.kind = TransactionSplitKind.expense,
    this.status,
    this.note,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isOwedByPerson => kind.isOwedByPerson;

  bool get isPending => isOwedByPerson && status != TransactionSplitStatus.paid;

  factory TransactionSplit.fromDb(Map<String, dynamic> row) {
    final createdAt = DateTime.tryParse(row['createdAt'] as String? ?? '');
    final updatedAt = DateTime.tryParse(row['updatedAt'] as String? ?? '');
    final now = DateTime.now();
    final kind = transactionSplitKindFromStorage(row['kind'] as String?);
    final status = transactionSplitStatusFromStorage(row['status'] as String?);
    return TransactionSplit(
      id: row['id'] as int?,
      parentReference: (row['parentReference'] as String?) ?? '',
      amount: (row['amount'] as num?)?.toDouble() ?? 0.0,
      categoryId: (row['categoryId'] as num?)?.toInt(),
      personId: (row['personId'] as num?)?.toInt(),
      kind: kind,
      status: kind.isOwedByPerson
          ? (status ?? TransactionSplitStatus.pending)
          : null,
      note: row['note'] as String?,
      createdAt: createdAt ?? now,
      updatedAt: updatedAt ?? createdAt ?? now,
    );
  }

  factory TransactionSplit.fromJson(Map<String, dynamic> json) {
    return TransactionSplit.fromDb({
      ...json,
      'id': json['id'] is int ? json['id'] : null,
    });
  }

  Map<String, dynamic> toDb() {
    return {
      if (id != null) 'id': id,
      'parentReference': parentReference,
      'amount': amount,
      'categoryId': categoryId,
      'personId': personId,
      'kind': kind.storageValue,
      'status': isOwedByPerson
          ? (status ?? TransactionSplitStatus.pending).storageValue
          : null,
      'note': note,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  Map<String, dynamic> toJson() => toDb();

  TransactionSplit copyWith({
    int? id,
    String? parentReference,
    double? amount,
    int? categoryId,
    bool clearCategory = false,
    int? personId,
    bool clearPerson = false,
    TransactionSplitKind? kind,
    TransactionSplitStatus? status,
    String? note,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return TransactionSplit(
      id: id ?? this.id,
      parentReference: parentReference ?? this.parentReference,
      amount: amount ?? this.amount,
      categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
      personId: clearPerson ? null : (personId ?? this.personId),
      kind: kind ?? this.kind,
      status: status ?? this.status,
      note: note ?? this.note,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
