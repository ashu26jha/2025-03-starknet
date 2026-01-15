use core::num::traits::{One, Zero};
use core::panics::panic_with_byte_array;
use perpetuals::core::errors::{
    position_not_deleveragable, position_not_fair_deleverage, position_not_healthy_nor_healthier,
    position_not_liquidatable,
};
use perpetuals::core::types::asset::synthetic::SyntheticAsset;
use perpetuals::core::types::balance::{Balance, BalanceDiff};
use perpetuals::core::types::position::{PositionDiffEnriched, PositionId};
use perpetuals::core::types::price::{Price, PriceMulTrait};
use perpetuals::core::types::risk_factor::RiskFactorTrait;
use starkware_utils::errors::assert_with_byte_array;
use starkware_utils::math::abs::Abs;
use starkware_utils::math::fraction::FractionTrait;

// This is the result of Price::One().mul(balance: 1)
// which is actually 1e-6 USDC * 2^28 / 2^28 = 1
const EPSILON: i128 = 1_i128;


/// Represents the state of a position based on its total value and total risk.
/// - A position is **Deleveragable** (and also **Liquidatable**) if its total value is negative.
/// - A position is **Liquidatable** if its total value is less than its total risk.
/// - Otherwise, the position is considered **Healthy**.
#[derive(Copy, Drop, Debug, PartialEq, Serde)]
pub enum PositionState {
    Healthy,
    Liquidatable,
    Deleveragable,
}

/// The total value and total risk of a position.
#[derive(Copy, Debug, Drop, Serde)]
pub struct PositionTVTR {
    pub total_value: i128,
    pub total_risk: u128,
}

/// The change in terms of total value and total risk of a position.
#[derive(Copy, Debug, Drop, Serde)]
pub struct TVTRChange {
    pub before: PositionTVTR,
    pub after: PositionTVTR,
}


/// Returns the state of a position based on its total value and total risk.
fn get_position_state(position_tvtr: PositionTVTR) -> PositionState {
    if position_tvtr.total_value < 0 {
        PositionState::Deleveragable
    } else if position_tvtr.total_value.abs() < position_tvtr.total_risk {
        // We apply abs() to total_value to be able to compare it with total_risk which is unsigned.
        // At this point, we've already ensured total_value is >= 0.
        PositionState::Liquidatable
    } else {
        PositionState::Healthy
    }
}

/// The position is fair if the total_value divided by the total_risk is the almost before and after
/// the change - the before_ratio needs to be between after_ratio-epsilon and after ratio.
fn is_fair_deleverage(before: PositionTVTR, after: PositionTVTR) -> bool {
    let before_ratio = FractionTrait::new(
        numerator: before.total_value, denominator: before.total_risk,
    );
    let after_ratio = FractionTrait::new(
        numerator: after.total_value, denominator: after.total_risk,
    );
    let after_minus_epsilon_ratio = FractionTrait::new(
        numerator: after.total_value - EPSILON, denominator: after.total_risk,
    );
    after_minus_epsilon_ratio < before_ratio && before_ratio <= after_ratio
}

/// Returns the state of a position.
pub fn evaluate_position(
    unchanged_synthetics: Span<SyntheticAsset>, collateral_balance: Balance,
) -> PositionState {
    let tvtr = calculate_position_tvtr(
        unchanged_synthetics: unchanged_synthetics, collateral_balance: collateral_balance,
    );
    get_position_state(position_tvtr: tvtr)
}

pub fn assert_healthy_or_healthier(position_id: PositionId, tvtr: TVTRChange) {
    let position_state_after_change = get_position_state(position_tvtr: tvtr.after);
    if position_state_after_change == PositionState::Healthy {
        // If the position is healthy we can return.
        return;
    }

    if tvtr.before.total_risk.is_zero() || tvtr.after.total_risk.is_zero() {
        panic_with_byte_array(@position_not_healthy_nor_healthier(:position_id));
    }

    /// This is checked only when the after is not healthy:
    /// The position is healthier if the total_value divided by the total_risk
    /// is equal or higher after the change and the total_risk is lower.
    /// Formal definition:
    /// total_value_after / total_risk_after >= total_value_before / total_risk_before
    /// AND total_risk_after < total_risk_before.
    if tvtr.after.total_risk >= tvtr.before.total_risk {
        panic_with_byte_array(@position_not_healthy_nor_healthier(:position_id));
    }
    let before_ratio = FractionTrait::new(tvtr.before.total_value, tvtr.before.total_risk);
    let after_ratio = FractionTrait::new(tvtr.after.total_value, tvtr.after.total_risk);

    assert_with_byte_array(
        after_ratio >= before_ratio, position_not_healthy_nor_healthier(:position_id),
    );
}

pub fn liquidated_position_validations(
    position_id: PositionId,
    unchanged_synthetics: Span<SyntheticAsset>,
    position_diff_enriched: PositionDiffEnriched,
) {
    let tvtr = calculate_position_tvtr_change(:unchanged_synthetics, :position_diff_enriched);
    let position_state_before_change = get_position_state(position_tvtr: tvtr.before);

    // Validate that the position isn't healthy before the change.
    assert_with_byte_array(
        position_state_before_change == PositionState::Liquidatable
            || position_state_before_change == PositionState::Deleveragable,
        position_not_liquidatable(:position_id),
    );
    assert_healthy_or_healthier(:position_id, :tvtr);
}

pub fn deleveraged_position_validations(
    position_id: PositionId,
    unchanged_synthetics: Span<SyntheticAsset>,
    position_diff_enriched: PositionDiffEnriched,
) {
    let tvtr = calculate_position_tvtr_change(:unchanged_synthetics, :position_diff_enriched);
    let position_state_before_change = get_position_state(position_tvtr: tvtr.before);

    assert_with_byte_array(
        position_state_before_change == PositionState::Deleveragable,
        position_not_deleveragable(:position_id),
    );

    assert_healthy_or_healthier(:position_id, :tvtr);
    assert_with_byte_array(
        is_fair_deleverage(before: tvtr.before, after: tvtr.after),
        position_not_fair_deleverage(:position_id),
    );
}

pub fn calculate_position_tvtr(
    unchanged_synthetics: Span<SyntheticAsset>, collateral_balance: Balance,
) -> PositionTVTR {
    let position_diff_enriched = PositionDiffEnriched {
        collateral_enriched: BalanceDiff { before: collateral_balance, after: collateral_balance },
        synthetic_enriched: Option::None,
    };
    calculate_position_tvtr_change(:unchanged_synthetics, :position_diff_enriched).before
}

/// Calculates the total value and total risk change for a position, taking into account both
/// unchanged assets and position changes (collateral and synthetic assets).
///
/// # Arguments
///
/// * `unchanged_assets` - Assets in the position that have not changed
/// * `position_diff_enriched` - Changes in collateral and synthetic assets for the position
///
/// # Returns
///
/// * `TVTRChange` - Contains the total value and total risk before and after the changes
///
/// # Logic Flow
/// 1. Calculates value and risk for unchanged assets
/// 2. Calculates value and risk changes for collateral assets
/// 3. Calculates value and risk changes for synthetic assets
/// 4. Combines all calculations into final before/after totals
pub fn calculate_position_tvtr_change(
    unchanged_synthetics: Span<SyntheticAsset>, position_diff_enriched: PositionDiffEnriched,
) -> TVTRChange {
    // Calculate the value and risk of the position data.
    let mut unchanged_synthetics_value = 0_i128;
    let mut unchanged_synthetics_risk = 0_u128;
    for synthetic in unchanged_synthetics {
        // asset_value is in units of 10^-6 USD.
        let asset_value: i128 = (*synthetic.price).mul(rhs: *synthetic.balance);
        unchanged_synthetics_value += asset_value;
        unchanged_synthetics_risk += (*synthetic.risk_factor).mul(asset_value.abs());
    }

    let mut total_value_before = unchanged_synthetics_value;
    let mut total_risk_before = unchanged_synthetics_risk;
    let mut total_value_after = unchanged_synthetics_value;
    let mut total_risk_after = unchanged_synthetics_risk;

    if let Option::Some(asset_diff) = position_diff_enriched.synthetic_enriched {
        // asset_value is in units of 10^-6 USD.
        let asset_value_before = asset_diff.price.mul(rhs: asset_diff.balance_before);
        let asset_value_after = asset_diff.price.mul(rhs: asset_diff.balance_after);

        total_value_before += asset_value_before;
        total_value_after += asset_value_after;

        total_risk_before += asset_diff.risk_factor_before.mul(asset_value_before.abs());
        total_risk_after += asset_diff.risk_factor_after.mul(asset_value_after.abs());
    }

    // Collateral price is always "One" in Perps - "One" is 10^-6 USD which means 2^28 same as the
    // PRICE_SCALE.
    let price: Price = One::one();
    // asset_value is in units of 10^-6 USD.
    total_value_before += price.mul(rhs: position_diff_enriched.collateral_enriched.before);
    total_value_after += price.mul(rhs: position_diff_enriched.collateral_enriched.after);

    TVTRChange {
        before: PositionTVTR { total_value: total_value_before, total_risk: total_risk_before },
        after: PositionTVTR { total_value: total_value_after, total_risk: total_risk_after },
    }
}