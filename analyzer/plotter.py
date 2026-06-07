"""
Plotter (Refactored)

This module contains visualization functions that work with pre-formatted DataFrames.
All data processing is done externally - these functions only handle plotting.
"""

import os
import datetime
import pandas as pd
import warnings
from plotnine.exceptions import PlotnineWarning
from plotnine import (
    ggplot, aes, geom_step, geom_point, labs, geom_vline, facet_wrap, 
    scale_color_manual, scale_linetype_manual, scale_x_continuous,
    scale_y_continuous, theme_bw, theme, element_blank
)

warnings.filterwarnings("ignore", category=PlotnineWarning)
os.environ['LIBGL_DEBUG'] = 'quiet'


def _calculate_x_breaks(max_time: float) -> list:
    """Calculate appropriate X-axis break points based on max time."""
    import math
    if max_time is None or (isinstance(max_time, float) and math.isnan(max_time)) or max_time <= 0:
        return [0, 60, 120]
    x_breaks = list(range(0, int(max_time) + 120, 120))
    if len(x_breaks) > 20:
        x_breaks = list(range(0, int(max_time) + 300, 300))
    elif len(x_breaks) < 4:
        x_breaks = list(range(0, int(max_time) + 15, 15))
    return x_breaks


def plot_cpu_load(df: pd.DataFrame, output_dir: str):
    """
    Plot CPU load by cluster over time.
    
    Args:
        df: DataFrame with columns: time_seconds, cpu_load_private, cpu_load_public
        output_dir: Directory to save the plot
    """
    required = ['time_seconds', 'cpu_load_private', 'cpu_load_public']
    if df.empty or not all(c in df.columns for c in required):
        print('⚠️  Skipping CPU load plot: no data available.')
        return

    plot_df = df.melt(
        id_vars=['time_seconds'], 
        value_vars=['cpu_load_private', 'cpu_load_public'],
        var_name='Cluster', 
        value_name='CPU Load'
    )
    plot_df['Cluster'] = plot_df['Cluster'].map({
        'cpu_load_private': 'Private', 
        'cpu_load_public': 'Public'
    })

    max_time = df['time_seconds'].max()
    x_breaks = _calculate_x_breaks(max_time)

    g = (
        ggplot(plot_df, aes(x='time_seconds', y='CPU Load', color='Cluster'))
        + geom_step(size=1.5)
        + labs(title="CPU Load by Cluster over time", y="CPU Load", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )

    timestamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S')
    filename = f"cpu_load_{timestamp}.png"
    output_path = os.path.join(output_dir, filename)
    g.save(output_path, width=12, height=6, dpi=300)


def plot_memory_load(df: pd.DataFrame, output_dir: str):
    """
    Plot memory load by cluster over time.
    
    Args:
        df: DataFrame with columns: time_seconds, mem_load_private, mem_load_public
        output_dir: Directory to save the plot
    """
    required = ['time_seconds', 'mem_load_private', 'mem_load_public']
    if df.empty or not all(c in df.columns for c in required):
        print('⚠️  Skipping memory load plot: no data available.')
        return

    plot_df = df.melt(
        id_vars=['time_seconds'], 
        value_vars=['mem_load_private', 'mem_load_public'],
        var_name='Cluster', 
        value_name='Memory Load'
    )
    plot_df['Cluster'] = plot_df['Cluster'].map({
        'mem_load_private': 'Private', 
        'mem_load_public': 'Public'
    })

    max_time = df['time_seconds'].max()
    x_breaks = _calculate_x_breaks(max_time)

    g = (
        ggplot(plot_df, aes(x='time_seconds', y='Memory Load', color='Cluster'))
        + geom_step(size=1.5)
        + labs(title="Memory Load by Cluster over time", y="Memory Load", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )

    timestamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S')
    filename = f"memory_load_{timestamp}.png"
    output_path = os.path.join(output_dir, filename)
    g.save(output_path, width=12, height=6, dpi=300)


def plot_total_percent_pending(df: pd.DataFrame, output_dir: str):
    """
    Plot total percent of pending pods over time.
    
    Args:
        df: DataFrame with columns: time_seconds, total_percent_pending
        output_dir: Directory to save the plot
    """
    if df.empty or 'time_seconds' not in df.columns or 'total_percent_pending' not in df.columns:
        print('⚠️  Skipping total percent pending plot: no data available.')
        return

    max_time = df['time_seconds'].max() if not df.empty else 0
    x_breaks = _calculate_x_breaks(max_time)

    plot_df = df.copy()
    plot_df['total_percent_pending'] = plot_df['total_percent_pending'] * 100

    g = (
        ggplot(plot_df, aes(x='time_seconds', y='total_percent_pending'))
        + geom_step(color='black', size=1)
        + labs(title="Total Percent Pending over time", y="Percent Pending (%)", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )

    timestamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S')
    filename = f"total_percent_pending_{timestamp}.png"
    output_path = os.path.join(output_dir, filename)
    g.save(output_path, width=12, height=6, dpi=300)


def plot_resource(
    df: pd.DataFrame, 
    value_vars: list, 
    cap_vars: list, 
    pending_vars: list, 
    title: str, 
    filename: str, 
    migration_data: pd.DataFrame = None
):
    """
    Generates a 4-panel plot for resource usage and pending pods.
    
    Args:
        df: DataFrame with resource data including timestamp, time_seconds columns
        value_vars: List of column names for resource usage (e.g., ['mem_allocated_public', ...])
        cap_vars: List of column names for capacity (e.g., ['cluster_memory_capacity_public', ...])
        pending_vars: List of column names for pending pods
        title: Plot title
        filename: Output filename (with path)
        migration_data: Optional DataFrame with migration events
        
    Layout:
    1. Top: Private Cluster - Pending Pods
    2. Mid-Top: Private Cluster - Resource Usage
    3. Mid-Bottom: Public Cluster - Resource Usage
    4. Bottom: Public Cluster - Pending Pods
    """
    df = df.copy()

    # Guard: se não há dados, não plota
    if df.empty or df['time_seconds'].isna().all() if 'time_seconds' in df.columns else df.empty:
        print(f"⚠️  Skipping plot '{title}': no data available.")
        return

    # Ensure time_seconds exists
    if 'time_seconds' not in df.columns and 'timestamp' in df.columns:
        start_time = df['timestamp'].min()
        df['time_seconds'] = (df['timestamp'] - start_time).dt.total_seconds()
    
    min_time = df['time_seconds'].min()
    df['time_seconds'] = df['time_seconds'] - min_time

    # Prepare Resource data (Usage and Capacity)
    df_usage_melt = df.melt(
        id_vars=['time_seconds'], 
        value_vars=value_vars, 
        var_name='metric', 
        value_name='value'
    )
    df_usage_melt['cluster'] = df_usage_melt['metric'].apply(
        lambda x: 'Public' if 'public' in x else 'Private'
    )
    df_usage_melt['type'] = 'Load'

    df_cap_melt = df.melt(
        id_vars=['time_seconds'], 
        value_vars=cap_vars, 
        var_name='metric', 
        value_name='value'
    )
    df_cap_melt['cluster'] = df_cap_melt['metric'].apply(
        lambda x: 'Public' if 'public' in x else 'Private'
    )
    df_cap_melt['type'] = 'Capacity'

    plot_df_resources = pd.concat([df_usage_melt, df_cap_melt], ignore_index=True)
    plot_df_resources['plot_group'] = plot_df_resources['cluster'].apply(
        lambda x: f'{x} Cluster Resources'
    )

    # Prepare Pending Pods data
    df_pending_melt = df.melt(
        id_vars=['time_seconds'], 
        value_vars=pending_vars, 
        var_name='metric', 
        value_name='value'
    )
    df_pending_melt['cluster'] = df_pending_melt['metric'].apply(
        lambda x: 'Public' if 'public' in x else 'Private'
    )
    df_pending_melt['type'] = 'Pending'
    df_pending_melt['plot_group'] = df_pending_melt['cluster'].apply(
        lambda x: f'{x} Cluster Pending Pods'
    )

    # Add reference points for pending pods to ensure proper scaling
    pending_groups = ['Private Cluster Pending Pods', 'Public Cluster Pending Pods']
    ref_points_data = []
    for group in pending_groups:
        ref_points_data.append({
            'plot_group': group, 
            'time_seconds': df['time_seconds'].min(), 
            'value': 0
        })
        ref_points_data.append({
            'plot_group': group, 
            'time_seconds': df['time_seconds'].min(), 
            'value': 1
        })
    ref_df = pd.DataFrame(ref_points_data)

    # Combine DataFrames
    plot_df = pd.concat([plot_df_resources, df_pending_melt], ignore_index=True)

    # Set plot order
    plot_order = [
        'Private Cluster Pending Pods',
        'Private Cluster Resources',
        'Public Cluster Resources',
        'Public Cluster Pending Pods'
    ]
    plot_df['plot_group'] = pd.Categorical(
        plot_df['plot_group'], 
        categories=plot_order, 
        ordered=True
    )

    categories = [
        'Load', 'Capacity', 'Pending', 'Migration to Private',
        'Migration to Public', 'Both Migrations', 'No Migration'
    ]
    plot_df['type'] = pd.Categorical(
        plot_df['type'],
        categories=categories,
        ordered=True
    )
    plot_df = plot_df.sort_values('type')

    # Color and linetype maps
    color_map = {
        'Load': '#d62728', 
        'Capacity': '#1f77b4', 
        'Pending': '#8c564b',
        'Migration to Private': '#9467bd', 
        'Migration to Public': '#ff7f0e', 
        'Both Migrations': '#2ca02c', 
        'No Migration': '#5f615f',
    }
    linetype_map = {
        'Load': 'solid', 
        'Capacity': 'dashed', 
        'Pending': 'solid',
        'Migration to Private': 'dotted', 
        'Migration to Public': 'dotted', 
        'Both Migrations': 'dotted', 
        'No Migration': 'dotted'
    }

    # Calculate X-axis intervals
    max_time = df['time_seconds'].max()
    x_breaks = _calculate_x_breaks(max_time)

    # Create the plot
    g = (
        ggplot(plot_df)
        + geom_step(
            aes(x='time_seconds', y='value', color='type', linetype='type'),
            size=1.5,
            na_rm=True
        )
        + geom_point(data=ref_df, mapping=aes(x='time_seconds', y='value'), alpha=0)
        + facet_wrap(
            '~plot_group',
            ncol=1,
            scales='free_y',
            labeller=lambda x: x.replace(" Resources", "").replace(
                " Pending Pods", "\n(Pending Pods)"
            )
        )
        + labs(title=title, y='Value', x='Time (seconds)', color='Legend', linetype='Legend')
        + scale_x_continuous(breaks=x_breaks, limits=(0, max_time))
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )

    # Add vertical lines for migrations
    if migration_data is not None and not migration_data.empty and 'timestamp' in df.columns:
        start_time = df['timestamp'].min()
        end_time = df['timestamp'].max()
        max_time_sec = (end_time - start_time).total_seconds()

        migration_data = migration_data.copy()
        migration_data['timestamp_dt'] = pd.to_datetime(migration_data['timestamp'], unit='s')
        
        # Subtract 3 hours from migration timestamps to align with metrics
        migration_data['timestamp_dt'] = migration_data['timestamp_dt'] - pd.Timedelta(hours=3)
        
        migration_data['xintercept'] = (
            migration_data['timestamp_dt'] - start_time
        ).dt.total_seconds()

        # Mapping for the legend
        migration_map = {
            'private': 'Migration to Private',
            'public': 'Migration to Public',
            'both': 'Both Migrations',
            'no migration': 'No Migration'
        }
        migration_data['mig_legend'] = migration_data['type'].map(migration_map)

        # Filter only valid values within the plot range
        migration_data_filtered = migration_data[
            (migration_data['xintercept'] >= 0) &
            (migration_data['xintercept'] <= max_time_sec)
        ]

        if not migration_data_filtered.empty:
            g += geom_vline(
                data=migration_data_filtered,
                mapping=aes(
                    xintercept='xintercept',
                    color='mig_legend',
                    linetype='mig_legend'
                ),
                size=1.5,
                show_legend=False
            )

    g += scale_color_manual(name='Legend', values=color_map)
    g += scale_linetype_manual(name='Legend', values=linetype_map)

    # Save the plot
    os.makedirs(os.path.dirname(filename) or '.', exist_ok=True)
    timestamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S')
    base, ext = os.path.splitext(filename)
    filename_with_timestamp = f"{base}_{timestamp}{ext}"
    g.save(filename_with_timestamp, width=16, height=12, dpi=300)


def plot_pricing(
    df: pd.DataFrame, 
    output_dir: str, 
    migration_data: pd.DataFrame = None, 
    instance_types: dict = None
):
    """
    Plot pricing data for both clusters.
    Creates a 4-panel layout: cost per interval and cumulative costs.
    
    Args:
        df: DataFrame with columns: time_seconds, timestamp, cost_public, cost_private,
            cumulative_cost_public, cumulative_cost_private
        output_dir: Directory to save the plot
        migration_data: Optional DataFrame with migration events
        instance_types: Dict with 'public' and 'private' instance type names
    """
    # Guard: se não há dados de pricing, não plota
    required_cols = ['time_seconds', 'cost_public', 'cost_private', 'cumulative_cost_public', 'cumulative_cost_private']
    if df.empty or not all(c in df.columns for c in required_cols):
        print("⚠️  Skipping pricing plot: no pricing data available.")
        return

    # Calculate X-axis intervals
    max_time = df['time_seconds'].max() if not df.empty else 0
    x_breaks = _calculate_x_breaks(max_time)

    # Prepare data for cost per interval plot
    plot_df_interval = df.melt(
        id_vars=['time_seconds'], 
        value_vars=['cost_public', 'cost_private'],
        var_name='cluster', 
        value_name='cost'
    )
    plot_df_interval['cluster'] = plot_df_interval['cluster'].map({
        'cost_public': 'Public', 
        'cost_private': 'Private'
    })
    plot_df_interval['type'] = 'Cost per Interval'
    plot_df_interval['plot_group'] = plot_df_interval['cluster'].apply(
        lambda x: f'{x} Cluster - Cost per Interval'
    )

    # Prepare data for cumulative cost plot
    plot_df_cumulative = df.melt(
        id_vars=['time_seconds'],
        value_vars=['cumulative_cost_public', 'cumulative_cost_private'],
        var_name='cluster', 
        value_name='cost'
    )
    plot_df_cumulative['cluster'] = plot_df_cumulative['cluster'].map({
        'cumulative_cost_public': 'Public', 
        'cumulative_cost_private': 'Private'
    })
    plot_df_cumulative['type'] = 'Cumulative Cost'
    plot_df_cumulative['plot_group'] = plot_df_cumulative['cluster'].apply(
        lambda x: f'{x} Cluster - Cumulative Cost'
    )

    # Combine dataframes
    plot_df = pd.concat([plot_df_interval, plot_df_cumulative], ignore_index=True)
    
    # Set plot order
    plot_order = [
        'Private Cluster - Cost per Interval',
        'Public Cluster - Cost per Interval',
        'Private Cluster - Cumulative Cost',
        'Public Cluster - Cumulative Cost'
    ]
    plot_df['plot_group'] = pd.Categorical(
        plot_df['plot_group'], 
        categories=plot_order, 
        ordered=True
    )

    # Color mapping
    color_map = {
        'Public': '#d62728',
        'Private': '#1f77b4',
        'Migration to Private': '#9467bd',
        'Migration to Public': '#ff7f0e',
        'Both Migrations': '#2ca02c',
        'No Migration': '#5f615f'
    }
    
    # Build title with instance types
    title = "Cluster Pricing Analysis"
    if instance_types:
        instance_parts = []
        if 'private' in instance_types:
            instance_parts.append(f"Private: {instance_types['private']}")
        if 'public' in instance_types:
            instance_parts.append(f"Public: {instance_types['public']}")
        if instance_parts:
            title += f" ({', '.join(instance_parts)})"

    # Create the base plot
    g = (
        ggplot(plot_df, aes(x='time_seconds', y='cost', color='cluster'))
        + geom_step(size=1.5)
        + facet_wrap('~plot_group', ncol=1, scales='free_y')
        + labs(title=title, y="Cost (USD)", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks, limits=(0, max_time))
        + scale_color_manual(name='Cluster', values=color_map)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )

    # Add migration events overlay if available
    if migration_data is not None and not migration_data.empty and 'timestamp' in df.columns:
        start_time = df['timestamp'].min()
        end_time = df['timestamp'].max()
        
        migration_data = migration_data.copy()
        migration_data['timestamp_dt'] = pd.to_datetime(migration_data['timestamp'], unit='s')
        
        # Subtract 3 hours from migration timestamps
        migration_data['timestamp_dt'] = migration_data['timestamp_dt'] - pd.Timedelta(hours=3)
        
        migration_data['xintercept'] = (
            migration_data['timestamp_dt'] - start_time
        ).dt.total_seconds()

        migration_map = {
            'private': 'Migration to Private',
            'public': 'Migration to Public',
            'both': 'Both Migrations',
            'no migration': 'No Migration'
        }
        migration_data['mig_legend'] = migration_data['type'].map(migration_map)

        migration_data_filtered = migration_data[
            (migration_data['xintercept'] >= 0) &
            (migration_data['xintercept'] <= max_time)
        ]

        if not migration_data_filtered.empty:
            migration_linetype_map = {
                'Migration to Private': 'dotted',
                'Migration to Public': 'dotted',
                'Both Migrations': 'dotted',
                'No Migration': 'dotted'
            }
            
            g += geom_vline(
                data=migration_data_filtered,
                mapping=aes(
                    xintercept='xintercept',
                    color='mig_legend',
                    linetype='mig_legend'
                ),
                size=1.5,
                show_legend=False
            )
            
            g += scale_linetype_manual(name='Migration Events', values=migration_linetype_map)

    # Save the plot
    timestamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S')
    filename = f"pricing_{timestamp}.png"
    output_path = os.path.join(output_dir, filename)
    g.save(output_path, width=12, height=14, dpi=300)


def plot_network_load(df: pd.DataFrame, output_dir: str, migration_data: pd.DataFrame = None):
    """
    Plot network load (receive and transmit) by cluster over time.
    Only works in REAL mode.
    Creates two separate plots: network_receive and network_transmit.
    
    Args:
        df: DataFrame with columns: time_seconds, network_receive_private, network_receive_public,
            network_transmit_private, network_transmit_public
        output_dir: Directory to save the plot
        migration_data: Optional DataFrame with migration events
    """
    if df.empty or 'network_receive_private' not in df.columns:
        return
    
    max_time = df['time_seconds'].max()
    x_breaks = _calculate_x_breaks(max_time)
    
    # Plot Network Receive
    receive_df = df.melt(
        id_vars=['time_seconds'],
        value_vars=['network_receive_private', 'network_receive_public'],
        var_name='Cluster',
        value_name='Network Receive'
    )
    receive_df['Cluster'] = receive_df['Cluster'].map({
        'network_receive_private': 'Private',
        'network_receive_public': 'Public'
    })
    
    g_receive = (
        ggplot(receive_df, aes(x='time_seconds', y='Network Receive', color='Cluster'))
        + geom_step(size=1.5)
        + labs(title="Network Receive by Cluster over time", y="Network Receive (bytes/sec)", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )
    
    # Plot Network Transmit
    transmit_df = df.melt(
        id_vars=['time_seconds'],
        value_vars=['network_transmit_private', 'network_transmit_public'],
        var_name='Cluster',
        value_name='Network Transmit'
    )
    transmit_df['Cluster'] = transmit_df['Cluster'].map({
        'network_transmit_private': 'Private',
        'network_transmit_public': 'Public'
    })
    
    g_transmit = (
        ggplot(transmit_df, aes(x='time_seconds', y='Network Transmit', color='Cluster'))
        + geom_step(size=1.5)
        + labs(title="Network Transmit by Cluster over time", y="Network Transmit (bytes/sec)", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )
    
    timestamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S')
    filename_receive = f"network_receive_{timestamp}.png"
    filename_transmit = f"network_transmit_{timestamp}.png"
    g_receive.save(os.path.join(output_dir, filename_receive), width=12, height=6, dpi=300)
    g_transmit.save(os.path.join(output_dir, filename_transmit), width=12, height=6, dpi=300)


def plot_io_load(df: pd.DataFrame, output_dir: str, migration_data: pd.DataFrame = None):
    """
    Plot I/O load (read and write) by cluster over time.
    Only works in REAL mode.
    Creates two separate plots: io_read and io_write.
    
    Args:
        df: DataFrame with columns: time_seconds, io_read_private, io_read_public,
            io_write_private, io_write_public
        output_dir: Directory to save the plot
        migration_data: Optional DataFrame with migration events
    """
    if df.empty or 'io_read_private' not in df.columns:
        return
    
    max_time = df['time_seconds'].max()
    x_breaks = _calculate_x_breaks(max_time)
    
    # Plot I/O Read
    read_df = df.melt(
        id_vars=['time_seconds'],
        value_vars=['io_read_private', 'io_read_public'],
        var_name='Cluster',
        value_name='I/O Read'
    )
    read_df['Cluster'] = read_df['Cluster'].map({
        'io_read_private': 'Private',
        'io_read_public': 'Public'
    })
    
    g_read = (
        ggplot(read_df, aes(x='time_seconds', y='I/O Read', color='Cluster'))
        + geom_step(size=1.5)
        + labs(title="Disk I/O Read by Cluster over time", y="I/O Read (bytes/sec)", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )
    
    # Plot I/O Write
    write_df = df.melt(
        id_vars=['time_seconds'],
        value_vars=['io_write_private', 'io_write_public'],
        var_name='Cluster',
        value_name='I/O Write'
    )
    write_df['Cluster'] = write_df['Cluster'].map({
        'io_write_private': 'Private',
        'io_write_public': 'Public'
    })
    
    g_write = (
        ggplot(write_df, aes(x='time_seconds', y='I/O Write', color='Cluster'))
        + geom_step(size=1.5)
        + labs(title="Disk I/O Write by Cluster over time", y="I/O Write (bytes/sec)", x="Time (seconds)")
        + scale_x_continuous(breaks=x_breaks)
        + scale_y_continuous(limits=(0, None))
        + theme_bw()
        + theme(legend_key=element_blank())
    )
    
    timestamp = datetime.datetime.now().strftime('%Y-%m-%d-%H-%M-%S')
    filename_read = f"io_read_{timestamp}.png"
    filename_write = f"io_write_{timestamp}.png"
    g_read.save(os.path.join(output_dir, filename_read), width=12, height=6, dpi=300)
    g_write.save(os.path.join(output_dir, filename_write), width=12, height=6, dpi=300)
