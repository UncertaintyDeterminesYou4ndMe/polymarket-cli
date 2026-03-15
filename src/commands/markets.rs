use anyhow::Result;
use clap::{Args, Subcommand};
use polymarket_client_sdk::gamma::{
    self,
    types::{
        request::{
            EventsRequest, MarketByIdRequest, MarketBySlugRequest, MarketTagsRequest,
            MarketsRequest, SearchRequest,
        },
        response::Market,
    },
};

use super::is_numeric_id;
use crate::output::OutputFormat;
use crate::output::markets::{print_market, print_markets};
use crate::output::tags::print_tags;

#[derive(Args)]
pub struct MarketsArgs {
    #[command(subcommand)]
    pub command: MarketsCommand,
}

#[derive(Subcommand)]
pub enum MarketsCommand {
    /// List markets with optional filters
    List {
        /// Filter by active status
        #[arg(long)]
        active: Option<bool>,

        /// Filter by closed status
        #[arg(long)]
        closed: Option<bool>,

        /// Max results
        #[arg(long, default_value = "25")]
        limit: i32,

        /// Pagination offset
        #[arg(long)]
        offset: Option<i32>,

        /// Sort field (e.g. `volume_num`, `liquidity_num`)
        #[arg(long)]
        order: Option<String>,

        /// Sort ascending instead of descending
        #[arg(long)]
        ascending: bool,

        /// Filter by tag slug (e.g. "politics", "crypto")
        #[arg(long)]
        tag: Option<String>,

        /// Minimum volume threshold (e.g. 100000 for $100k)
        #[arg(long)]
        min_volume: Option<f64>,
    },

    /// Get a single market by ID or slug
    Get {
        /// Market ID (numeric) or slug
        id: String,
    },

    /// Search markets
    Search {
        /// Search query string
        query: String,

        /// Results per type
        #[arg(long, default_value = "10")]
        limit: i32,
    },

    /// Get tags for a market
    Tags {
        /// Market ID
        id: String,
    },

    /// List trending markets by 24h volume
    Trending {
        /// Max results
        #[arg(long, default_value = "10")]
        limit: i32,

        /// Filter by tag slug (e.g. "politics", "crypto")
        #[arg(long)]
        tag: Option<String>,

        /// Minimum 24h volume threshold
        #[arg(long)]
        min_volume_24h: Option<f64>,
    },
}

pub async fn execute(
    client: &gamma::Client,
    args: MarketsArgs,
    output: OutputFormat,
) -> Result<()> {
    match args.command {
        MarketsCommand::List {
            active,
            closed,
            limit,
            offset,
            order,
            ascending,
            tag,
            min_volume,
        } => {
            let resolved_closed = closed.or_else(|| active.map(|a| !a));

            let mut markets = if let Some(tag_slug) = tag {
                // Use events API to filter by tag, then flatten markets
                let request = EventsRequest::builder()
                    .limit(limit * 2) // Fetch more events to get enough markets
                    .maybe_closed(resolved_closed)
                    .ascending(ascending)
                    .maybe_tag_slug(Some(tag_slug))
                    .order(order.clone().into_iter().collect())
                    .build();

                let events = client.events(&request).await?;
                events
                    .into_iter()
                    .flat_map(|e| e.markets.unwrap_or_default())
                    .collect::<Vec<Market>>()
            } else {
                let request = MarketsRequest::builder()
                    .limit(limit)
                    .maybe_closed(resolved_closed)
                    .maybe_offset(offset)
                    .maybe_order(order)
                    .ascending(ascending)
                    .build();

                client.markets(&request).await?
            };

            // Apply min_volume filter if specified
            if let Some(min_vol) = min_volume {
                markets.retain(|m| {
                    m.volume_num
                        .map(|v| v.to_string().parse::<f64>().unwrap_or(0.0) >= min_vol)
                        .unwrap_or(false)
                });
            }

            // Apply limit after filtering
            markets.truncate(limit as usize);

            print_markets(&markets, &output)?;
        }

        MarketsCommand::Get { id } => {
            let is_numeric = is_numeric_id(&id);
            let market = if is_numeric {
                let req = MarketByIdRequest::builder().id(id).build();
                client.market_by_id(&req).await?
            } else {
                let req = MarketBySlugRequest::builder().slug(id).build();
                client.market_by_slug(&req).await?
            };

            print_market(&market, &output)?;
        }

        MarketsCommand::Search { query, limit } => {
            let request = SearchRequest::builder()
                .q(query)
                .limit_per_type(limit)
                .build();

            let results = client.search(&request).await?;

            let markets: Vec<Market> = results
                .events
                .unwrap_or_default()
                .into_iter()
                .flat_map(|e| e.markets.unwrap_or_default())
                .collect();

            print_markets(&markets, &output)?;
        }

        MarketsCommand::Tags { id } => {
            let req = MarketTagsRequest::builder().id(id).build();
            let tags = client.market_tags(&req).await?;

            print_tags(&tags, &output)?;
        }

        MarketsCommand::Trending {
            limit,
            tag,
            min_volume_24h,
        } => {
            // Fetch markets (without API-side sorting as it may not support volume_num)
            let mut markets = if let Some(tag_slug) = tag {
                let request = EventsRequest::builder()
                    .limit(50)
                    .maybe_closed(Some(false))
                    .maybe_tag_slug(Some(tag_slug))
                    .build();

                let events = client.events(&request).await?;
                events
                    .into_iter()
                    .flat_map(|e| e.markets.unwrap_or_default())
                    .collect::<Vec<Market>>()
            } else {
                let request = MarketsRequest::builder()
                    .limit(50)
                    .maybe_closed(Some(false))
                    .build();

                client.markets(&request).await?
            };

            // Sort by 24h volume (trending indicator)
            markets.sort_by(|a, b| {
                let vol_a = a
                    .volume_24hr
                    .and_then(|v| v.to_string().parse::<f64>().ok())
                    .unwrap_or(0.0);
                let vol_b = b
                    .volume_24hr
                    .and_then(|v| v.to_string().parse::<f64>().ok())
                    .unwrap_or(0.0);
                vol_b.partial_cmp(&vol_a).unwrap_or(std::cmp::Ordering::Equal)
            });

            // Apply min_volume_24h filter if specified
            if let Some(min_vol) = min_volume_24h {
                markets.retain(|m| {
                    m.volume_24hr
                        .map(|v| v.to_string().parse::<f64>().unwrap_or(0.0) >= min_vol)
                        .unwrap_or(false)
                });
            }

            // Apply limit
            markets.truncate(limit as usize);

            // Use a custom output format that shows 24h volume
            crate::output::markets::print_trending_markets(&markets, &output)?;
        }
    }

    Ok(())
}
