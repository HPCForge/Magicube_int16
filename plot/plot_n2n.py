import re
import six
import csv
import seaborn as sns
import matplotlib.pyplot as plt
import pandas as pd

#sns.set_context(rc = {'patch.linewidth': 0.0})
order = ['Pytorch-fp16', 'vectorSparse-fp16', 'Magicube-16b8b', 'Magicube-8b8b', 'Magicube-8b4b', 'Magicube-4b4b']

n2n_a_data = pd.read_csv('n2n_a.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.9,Seq_l=4096,num_h=4", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
#plt.xticks(rotation=20)
g.tick_params(labelsize=8)
g.set(ylim=(0, 25))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.9, Seq_len=4096, num_h=4')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-a.pdf')

n2n_a_data = pd.read_csv('n2n_b.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.9,Seq_l=4096,num_h=8", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
g.tick_params(labelsize=8)
g.set(ylim=(0, 50))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.9, Seq_len=4096, num_h=8')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-b.pdf')

n2n_a_data = pd.read_csv('n2n_c.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.9,Seq_l=8192,num_h=4", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
g.tick_params(labelsize=8)
g.set(ylim=(0, 70))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.9, Seq_len=8192, num_h=4')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-c.pdf')

n2n_a_data = pd.read_csv('n2n_d.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.9,Seq_l=8192,num_h=8", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
g.tick_params(labelsize=8)
g.set(ylim=(0, 150))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.9, Seq_len=8192, num_h=8')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-d.pdf')


n2n_a_data = pd.read_csv('n2n_e.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.95,Seq_l=4096,num_h=4", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
#plt.xticks(rotation=20)
g.tick_params(labelsize=8)
g.set(ylim=(0, 25))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.95, Seq_len=4096, num_h=4')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-e.pdf')

n2n_a_data = pd.read_csv('n2n_f.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.95,Seq_l=4096,num_h=8", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
g.tick_params(labelsize=8)
g.set(ylim=(0, 50))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.95, Seq_len=4096, num_h=8')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-f.pdf')

n2n_a_data = pd.read_csv('n2n_g.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.95,Seq_l=8192,num_h=4", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
g.tick_params(labelsize=8)
g.set(ylim=(0, 70))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.95, Seq_len=8192, num_h=4')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-g.pdf')

n2n_a_data = pd.read_csv('n2n_h.csv')
sns.set(rc={"lines.linewidth": 0.5})
sns.set(rc={'figure.figsize':(5, 3)})
g = sns.barplot(data=n2n_a_data, x="S0.95,Seq_l=8192,num_h=8", y="Latency(ms)", hue="algs", palette="Blues_d", hue_order=order, ci=95, capsize=.1, errwidth=0.8)
g.tick_params(labelsize=8)
g.set(ylim=(0, 150))
g.set_xlabel(" ", fontsize=8)
g.set_title('Sparsity=0.95, Seq_len=8192, num_h=8')
plt.setp(g.get_legend().get_texts(), fontsize='6')
plt.setp(g.get_legend().get_title(), fontsize='6')
g.figure.savefig('./figs/Figure16-h.pdf')
