/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   coercion.rs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/29 12:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/29 12:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

//! The type-coercion contract: what happens to a value moved from a column of
//! one [`NormalizedType`] to another, whichever engines hold them. Cross-engine
//! migration (G8) consults it to build the dry-run report before writing.
//!
//! `Lossless` means every source value converts and converts back unchanged.
//! `Lossy` means the column converts but some values do not survive, for the
//! stated reason (those rows are refused, never silently altered). `Refused`
//! means the conversion has no meaning. `Integer` is read as "fits in 32 bits"
//! and `Bigint` as 64 bits, the split the normalizers adopt in G7b.

use crate::NormalizedType;

/// Outcome of moving a column's values from one type to another.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Coercion {
    Lossless,
    Lossy { reason: &'static str },
    Refused { reason: &'static str },
}

const PARSE: &str = "values that do not parse as the target type are refused per row";

/// The coercion from `from` to `to`.
#[must_use]
pub fn coercion(from: NormalizedType, to: NormalizedType) -> Coercion {
    use Coercion::{Lossless, Lossy, Refused};
    use NormalizedType as N;
    if from == to {
        return Lossless;
    }
    match (from, to) {
        (_, N::Objectid | N::Geometry | N::Vector | N::Unknown) => Refused {
            reason: "the target type is describe-only; no engine creates it from a request",
        },
        (N::Unknown, N::Text | N::Json) => Lossy {
            reason: "an unknown native type is copied as its text form",
        },
        (N::Unknown, _) => Refused {
            reason: "the source's native type is unknown",
        },
        // Every known type has a canonical text (and JSON) form that parses back.
        (_, N::Text | N::Json) | (N::Text, N::Binary) => Lossless,
        (N::Text | N::Json, _) => Lossy { reason: PARSE },
        (N::Boolean, N::Integer | N::Bigint | N::Float | N::Decimal)
        | (N::Integer, N::Bigint | N::Float | N::Decimal)
        | (N::Bigint, N::Decimal)
        | (N::Date, N::Datetime)
        | (N::Uuid | N::Objectid, N::Binary) => Lossless,
        (N::Bigint, N::Integer) => Lossy {
            reason: "values outside 32 bits are refused per row",
        },
        (N::Bigint, N::Float) => Lossy {
            reason: "integers beyond 2^53 lose their low digits",
        },
        (N::Float, N::Decimal) => Lossy {
            reason: "NaN and Infinity have no decimal form",
        },
        (N::Decimal, N::Float) => Lossy {
            reason: "digits beyond double precision round",
        },
        (N::Float | N::Decimal, N::Integer | N::Bigint) => Lossy {
            reason: "non-integral values are refused per row",
        },
        (N::Integer | N::Bigint | N::Float | N::Decimal, N::Boolean) => Lossy {
            reason: "only 0 and 1 convert",
        },
        (N::Datetime, N::Date) => Lossy {
            reason: "the time of day is dropped",
        },
        (N::Datetime, N::Time) => Lossy {
            reason: "the date is dropped",
        },
        (N::Binary, N::Uuid) => Lossy {
            reason: "only 16-byte values convert",
        },
        _ => Refused {
            reason: "no conversion keeps these values meaningful",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use NormalizedType as N;

    const ALL: [NormalizedType; 19] = [
        N::Text,
        N::Integer,
        N::Float,
        N::Decimal,
        N::Boolean,
        N::Date,
        N::Datetime,
        N::Json,
        N::Uuid,
        N::Enum,
        N::Array,
        N::Objectid,
        N::Binary,
        N::Time,
        N::Interval,
        N::Bigint,
        N::Geometry,
        N::Vector,
        N::Unknown,
    ];

    // A new variant breaks this match, which is the reminder to add it to ALL.
    fn all_is_complete(ty: NormalizedType) {
        match ty {
            N::Text | N::Integer | N::Float | N::Decimal | N::Boolean | N::Date | N::Datetime => {}
            N::Json | N::Uuid | N::Enum | N::Array | N::Objectid | N::Binary | N::Time => {}
            N::Interval | N::Bigint | N::Geometry | N::Vector | N::Unknown => {}
        }
    }

    #[test]
    fn every_pair_obeys_the_contract() {
        ALL.into_iter().for_each(all_is_complete);
        for from in ALL {
            for to in ALL {
                let got = coercion(from, to);
                if from == to {
                    assert_eq!(got, Coercion::Lossless, "{from:?} → itself");
                    continue;
                }
                if matches!(to, N::Objectid | N::Geometry | N::Vector | N::Unknown) {
                    assert!(matches!(got, Coercion::Refused { .. }), "{from:?} → {to:?}");
                }
                if from != N::Unknown && matches!(to, N::Text | N::Json) {
                    assert_eq!(got, Coercion::Lossless, "{from:?} → {to:?}");
                }
                if let Coercion::Lossy { reason } | Coercion::Refused { reason } = got {
                    assert!(!reason.is_empty(), "{from:?} → {to:?}");
                }
            }
        }
    }

    #[test]
    fn widening_is_lossless_and_narrowing_names_its_loss() {
        assert_eq!(coercion(N::Integer, N::Bigint), Coercion::Lossless);
        assert_eq!(coercion(N::Date, N::Datetime), Coercion::Lossless);
        assert_eq!(coercion(N::Uuid, N::Binary), Coercion::Lossless);
        assert!(matches!(
            coercion(N::Bigint, N::Integer),
            Coercion::Lossy { .. }
        ));
        assert!(matches!(
            coercion(N::Datetime, N::Date),
            Coercion::Lossy { .. }
        ));
        assert!(matches!(
            coercion(N::Text, N::Integer),
            Coercion::Lossy { .. }
        ));
        assert!(matches!(
            coercion(N::Unknown, N::Text),
            Coercion::Lossy { .. }
        ));
        assert!(matches!(
            coercion(N::Interval, N::Integer),
            Coercion::Refused { .. }
        ));
        assert!(matches!(
            coercion(N::Boolean, N::Date),
            Coercion::Refused { .. }
        ));
    }
}
